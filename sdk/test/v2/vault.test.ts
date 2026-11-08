// Offline tests for SDK v2. Reference values were read from the live EPKVault 2.3.0 guard demo vault on BSC Testnet
// (0x3Bdd9c884B168bbFa41C181328548a5e42180FD3): the vault's own getExecuteDigest / hashOperation.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { privateKeyToAccount } from "viem/accounts";
import { recoverTypedDataAddress, decodeFunctionData, type Hex } from "viem";

import {
  executeDigest,
  executeTypedData,
  hashOperation,
  decodeEpkError,
  v2SwapExactTokens,
  v2SwapExactNative,
  v2RouterAbi,
  SESSION_ID_BASE,
} from "../../src/v2/index.js";

const VAULT = "0x3Bdd9c884B168bbFa41C181328548a5e42180FD3";
const OPERATOR = "0x80ddc9C233ff9fef6e14EB1518AF0d42010798ef";
const TUSD = "0xc58699856ED5c978F7bf47e46650Bdb23d9bB119";
const ROUTER = "0xD99D1c33F9fC3444f8101754aBC46c52416550D1";
const WBNB = "0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd";
const TRANSFER: Hex =
  "0xa9059cbb000000000000000000000000c93ec67f65530e5997e0a54826d1de1243e204dd0000000000000000000000000000000000000000000000000de0b6b3a7640000";

const message = {
  policyId: 0n,
  agent: OPERATOR,
  calls: [
    { target: TUSD, value: 0n, data: TRANSFER },
    { target: ROUTER, value: 100000000000000n, data: "0x1234" as Hex },
  ],
  nonce: 7n,
  deadline: 1800000000n,
} as const;

test("executeDigest equals the vault's own getExecuteDigest", () => {
  assert.equal(executeDigest(97, VAULT, message), "0x24f37c36eb1c9c1a5d775369a7649e82be0606b4af54c5a85dbbf2b571c2f4c1");
});

test("the digest depends on chain, vault, nonce and every call", () => {
  const base = executeDigest(97, VAULT, message);
  assert.notEqual(executeDigest(56, VAULT, message), base);
  assert.notEqual(executeDigest(97, OPERATOR, message), base);
  assert.notEqual(executeDigest(97, VAULT, { ...message, nonce: 8n }), base);
  assert.notEqual(executeDigest(97, VAULT, { ...message, calls: [message.calls[0]] }), base);
  assert.notEqual(
    executeDigest(97, VAULT, { ...message, calls: [message.calls[0], { ...message.calls[1], value: 1n }] }),
    base,
  );
});

test("a signature over the typed data recovers the signer", async () => {
  const account = privateKeyToAccount("0x000000000000000000000000000000000000000000000000000000000000beef");
  const typed = executeTypedData(97, VAULT, message);
  const signature = await account.signTypedData(typed);
  assert.equal(await recoverTypedDataAddress({ ...typed, signature }), account.address);
});

test("hashOperation equals the vault's hashOperation", () => {
  assert.equal(
    hashOperation("0xabcdef", "0x0000000000000000000000000000000000000000000000000000000000000001"),
    "0x39bd256e83839d778eb558848e4772d9316f27132d4823c95cd8663c9ba93e0a",
  );
});

test("session ids start at 2^128", () => {
  assert.equal(SESSION_ID_BASE, 340282366920938463463374607431768211456n);
});

test("swap batches: approve, swap to the vault, allowance reset", () => {
  const calls = v2SwapExactTokens({
    router: ROUTER,
    vault: VAULT,
    path: [TUSD, WBNB],
    amountIn: 5n,
    minOut: 4n,
    deadline: 1800000000n,
  });
  assert.equal(calls.length, 3);
  assert.equal(calls[0].target, TUSD);
  assert.equal(calls[2].target, TUSD);
  const swap = decodeFunctionData({ abi: v2RouterAbi, data: calls[1].data });
  assert.equal(swap.functionName, "swapExactTokensForTokens");
  assert.equal((swap.args as readonly unknown[])[3], VAULT);

  const native = v2SwapExactNative({ router: ROUTER, vault: VAULT, path: [WBNB, TUSD], amountIn: 7n, minOut: 1n, deadline: 1n });
  assert.equal(native.length, 1);
  assert.equal(native[0].value, 7n);
});

test("decodeEpkError names every on-chain rejection of the testnet guard demo", () => {
  const root = "../deployments/bsc-testnet";
  const evidence = JSON.parse(readFileSync(`${root}/epk-guards-evidence.json`, "utf8"));
  const traces = new Set(readdirSync(`${root}/traces`));
  let checked = 0;
  for (const t of evidence.transactions) {
    if (t.expect !== "reverted") continue;
    const file = `${t.tx.toLowerCase()}.json`;
    assert.ok(traces.has(file), `trace for ${t.step}`);
    const out = JSON.parse(readFileSync(`${root}/traces/${file}`, "utf8")).trace.output as Hex;
    const decoded = decodeEpkError(out);
    assert.equal(decoded?.errorName, t.error.split("(")[0], `step ${t.step}`);
    checked++;
  }
  assert.equal(checked, 12);
});
