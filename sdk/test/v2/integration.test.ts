// Offline tests for the integrator-facing helpers: configuration actions, error explanations, presets.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { encodeErrorResult, encodeFunctionData, isAddress, maxUint128, parseAbi, type Hex } from "viem";

import {
  vaultActions,
  selector,
  NATIVE_TRANSFER,
  NATIVE,
  epkVaultAbi,
  dexGuardAbi,
  threatFeedGuardAbi,
  compositeGuardAbi,
  epkErrorHelp,
  explainEpkError,
  networks,
} from "../../src/v2/index.js";

test("configuration actions encode exactly the vault's functions", () => {
  const a = vaultActions.setAsset(NATIVE, 10n ** 16n, 86400);
  assert.equal(a.data, encodeFunctionData({ abi: epkVaultAbi, functionName: "setAsset", args: [NATIVE, 10n ** 16n, 86400, maxUint128] }));
  const p = vaultActions.createPolicy("0x0000000000000000000000000000000000000001", 0, 10n ** 15n);
  assert.equal(p.functionName, "createPolicy");
  assert.deepEqual(p.args, ["0x0000000000000000000000000000000000000001", 0, 10n ** 15n, NATIVE]);
  const c = vaultActions.setCall(0n, "0x0000000000000000000000000000000000000002", NATIVE_TRANSFER);
  assert.equal(c.data.slice(0, 10), encodeFunctionData({ abi: epkVaultAbi, functionName: "setCall", args: [0n, "0x0000000000000000000000000000000000000002", "0x00000000", true] }).slice(0, 10));
  assert.equal(selector("transfer(address,uint256)"), "0xa9059cbb");
  assert.ok(vaultActions.addDestination("0x0000000000000000000000000000000000000003").label.includes("allow payments"));
});

// errors from OpenZeppelin internals or from feed / composite management, not from a vault batch
const NOT_BATCH = new Set([
  "AddressEmptyCode", "ERC1967InvalidImplementation", "ERC1967NonPayable", "InvalidInitialization",
  "NotInitializing", "UUPSUnauthorizedCallContext", "UUPSUnsupportedProxiableUUID", "SafeCastOverflowedUintToInt",
  "NotOwner", "NotOwnerOrBlocker", "NotBlocked", "NotReady", "NotScheduled", "TooMany", "BadChildren",
]);

test("every error a vault batch can return has a plain explanation", () => {
  const names = new Set(
    [...epkVaultAbi, ...dexGuardAbi, ...threatFeedGuardAbi, ...compositeGuardAbi]
      .filter((x) => x.type === "error")
      .map((x) => (x as { name: string }).name)
      .filter((n) => !NOT_BATCH.has(n)),
  );
  const missing = [...names].filter((n) => !epkErrorHelp[n]);
  assert.deepEqual(missing, []);
});

test("explainEpkError turns every on-chain rejection of the testnet demo into advice", () => {
  const root = "../deployments/bsc-testnet";
  const ev = JSON.parse(readFileSync(`${root}/epk-guards-evidence.json`, "utf8"));
  const traces = new Set(readdirSync(`${root}/traces`));
  for (const t of ev.transactions.filter((x: { expect: string }) => x.expect === "reverted")) {
    const out = JSON.parse(readFileSync(`${root}/traces/${t.tx.toLowerCase()}.json`, "utf8")).trace.output as Hex;
    assert.ok(traces.size > 0);
    const text = explainEpkError(out);
    assert.ok(text.startsWith(t.error.split("(")[0]), text);
    assert.ok(text.includes("→"), `no advice for ${t.step}: ${text}`);
  }
  const boom = encodeErrorResult({ abi: parseAbi(["error Error(string)"]), errorName: "Error", args: ["boom"] });
  assert.equal(explainEpkError(boom), "revert: boom");
});

test("network presets are valid addresses", () => {
  const walk = (o: unknown): string[] => (typeof o === "string" ? [o] : typeof o === "object" && o ? Object.values(o).flatMap(walk) : []);
  for (const a of walk(networks.bscTestnet).filter((x) => x.startsWith("0x"))) assert.ok(isAddress(a), a);
  for (const a of walk(networks.opbnbTestnet).filter((x) => x.startsWith("0x"))) assert.ok(isAddress(a), a);
  assert.equal(networks.bscTestnet.chainId, 97);
  assert.equal(networks.opbnbTestnet.chainId, 5611);
});

// ---- internal audit 2026-11-08: SDK protections

test("explainEpkError never pushes the owner to loosen rules on an error alone", () => {
  const data = encodeErrorResult({ abi: epkVaultAbi, errorName: "DestinationNotAllowed", args: ["0x000000000000000000000000000000000000bad1"] });
  assert.match(explainEpkError(data), /confirm on the vault before loosening/);
  const guardErr = encodeErrorResult({ abi: dexGuardAbi, errorName: "RecipientNotAllowed", args: ["0x000000000000000000000000000000000000beef"] });
  assert.match(explainEpkError(guardErr), /never transfer to it/);
  const limit = encodeErrorResult({ abi: dexGuardAbi, errorName: "PriceLimitNotAllowed" });
  assert.match(explainEpkError(limit), /sqrtPriceLimitX96 to 0/);
});

test("signBatch refuses to sign when the signer and the RPC are on different chains", async () => {
  const { createPublicClient, createWalletClient, custom } = await import("viem");
  const { privateKeyToAccount } = await import("viem/accounts");
  const { bsc } = await import("viem/chains");
  const { EPKVaultClient } = await import("../../src/v2/index.js");
  const rpc = custom({ request: async ({ method }: { method: string }) => (method === "eth_chainId" ? "0x61" : "0x0") }); // BSC Testnet
  const publicClient = createPublicClient({ transport: rpc });
  const signer = createWalletClient({ account: privateKeyToAccount(`0x${"11".repeat(32)}`), chain: bsc, transport: rpc }); // BSC mainnet
  const vault = new EPKVaultClient({ address: networks.bscTestnet.demo.guardVault, publicClient: publicClient as never });
  await assert.rejects(
    vault.signBatch({ policyId: 0n, agent: signer.account.address, calls: [], signer: signer as never, nonce: 0n, deadline: 1n }),
    /signer is on chain 56 but the public client is on chain 97/,
  );
});

test("coSignBatch signs only with the vault's own co-signer, on the vault's chain", async () => {
  const { createPublicClient, createWalletClient, custom, encodeAbiParameters, recoverTypedDataAddress } = await import("viem");
  const { privateKeyToAccount } = await import("viem/accounts");
  const { bsc, bscTestnet } = await import("viem/chains");
  const { EPKVaultClient, coSignTypedData, executeDigest } = await import("../../src/v2/index.js");
  const coSigner = privateKeyToAccount(`0x${"22".repeat(32)}`);
  const stranger = privateKeyToAccount(`0x${"33".repeat(32)}`);
  let onChain: `0x${string}` = coSigner.address; // what the vault's coSigner() returns
  const rpc = custom({
    request: async ({ method }: { method: string }) =>
      method === "eth_chainId" ? "0x61" : method === "eth_call" ? encodeAbiParameters([{ type: "address" }], [onChain]) : "0x0",
  });
  const publicClient = createPublicClient({ transport: rpc });
  const vaultAddress = networks.bscTestnet.demo.guardVault;
  const vault = new EPKVaultClient({ address: vaultAddress, publicClient: publicClient as never });
  const message = { policyId: 0n, agent: coSigner.address, calls: [], nonce: 3n, deadline: 1800000000n };
  const wallet = (account: typeof coSigner, chain = bscTestnet) => createWalletClient({ account, chain, transport: rpc }) as never;

  await assert.rejects(vault.coSignBatch({ message, signer: wallet(stranger) }), /is not this vault's co-signer/);
  await assert.rejects(vault.coSignBatch({ message, signer: wallet(coSigner, bsc as never) }), /signer is on chain 56 but the public client is on chain 97/);

  const out = await vault.coSignBatch({ message, signer: wallet(coSigner) });
  assert.equal(out.digest, executeDigest(97, vaultAddress, message));
  const typed = coSignTypedData(97, vaultAddress, out.digest);
  assert.equal(await recoverTypedDataAddress({ ...typed, signature: out.coSignature }), coSigner.address);

  onChain = "0x0000000000000000000000000000000000000000";
  await assert.rejects(vault.coSignBatch({ message, signer: wallet(coSigner) }), /has no co-signer/);
});
