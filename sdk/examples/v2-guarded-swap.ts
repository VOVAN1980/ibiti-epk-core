// SDK v2 walkthrough against the EPK 2.1 guard demo on BSC Testnet. Read-only: it signs and SIMULATES,
// it never sends a transaction.
//   npm run example:v2            (the operator key V21_OPERATOR_PRIVATE_KEY in ../.env is optional:
//                                  without it the signing and simulation steps are skipped)
import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, http, formatUnits, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { bscTestnet } from "viem/chains";

import { EPKVaultClient, DexGuardClient, planGuardedSwap, v2SwapExactNative, NATIVE } from "../src/v2/index.js";

const dep = JSON.parse(readFileSync("../deployments/bsc-testnet/epk-v2.1.json", "utf8")) as Record<string, string>;
const rpc = process.env.BSC_TESTNET_RPC ?? "https://bsc-testnet-rpc.publicnode.com";
const publicClient = createPublicClient({ chain: bscTestnet, transport: http(rpc) });
const vault = new EPKVaultClient({ address: dep.vault as Address, publicClient });
const guard = new DexGuardClient(dep.dexGuard as Address, publicClient);

function envKey(name: string): Hex | undefined {
  try {
    const line = readFileSync("../.env", "utf8").split(/\r?\n/).find((l) => l.startsWith(name + "="));
    return line ? (line.slice(name.length + 1).trim() as Hex) : undefined;
  } catch {
    return undefined;
  }
}

async function main() {
  console.log(`vault ${vault.address}: version ${await vault.version()}, paused ${await vault.paused()}`);
  console.log(`  may still send today: ${formatUnits(await vault.availableToSpend(NATIVE), 18)} BNB, ` +
    `${formatUnits(await vault.availableToSpend(dep.tusd as Address), 18)} tUSD`);
  console.log(`  guard of agent sessions (envelope 1): ${await vault.envelopeGuard(1n)}`);
  console.log(`DexGuard: ${await guard.maxSlippageBps()} bps slippage, deadlines up to ${await guard.maxDeadline()} s, ` +
    `BNB = $${formatUnits(await guard.price(dep.wbnb as Address), 18)} (Chainlink)`);

  // 1) the demo's own tUSD pool (seeded at the Chainlink price; it drifts as BNB moves and nobody arbitrages it)
  const amountIn = 100_000_000_000_000n; // 0.0001 BNB
  let calls = v2SwapExactNative({
    router: dep.router as Address, vault: vault.address, path: [dep.wbnb as Address, dep.tusd as Address], amountIn,
    minOut: await guard.minimumOut(dep.wbnb as Address, dep.tusd as Address, amountIn),
    deadline: (await publicClient.getBlock()).timestamp + 300n,
  });
  try {
    const fair = await planGuardedSwap({
      publicClient, guard: dep.dexGuard as Address, router: dep.router as Address, vault: vault.address,
      path: [dep.wbnb as Address, dep.tusd as Address], amountIn, native: true,
    });
    calls = fair.calls;
    console.log(`tUSD pool: quote ${fair.quote}, guard minimum ${fair.guardMinimum}, signing minOut ${fair.minOut} -> OK`);
  } catch (e) {
    console.log(`tUSD pool right now: ${(e as Error).message}`);
  }

  // 2) the real WBNB/BUSD testnet pool, ~38 % below Chainlink: refused before any gas is spent
  try {
    await planGuardedSwap({
      publicClient, guard: dep.dexGuard as Address, router: dep.router as Address, vault: vault.address,
      path: [dep.wbnb as Address, dep.busd as Address], amountIn: 100_000_000_000_000n, native: true,
    });
  } catch (e) {
    console.log(`real WBNB/BUSD pool: ${(e as Error).message}`);
  }

  // 3) sign and simulate with the operator key (if present locally)
  const pk = envKey("V21_OPERATOR_PRIVATE_KEY");
  if (!pk) return console.log("(no V21_OPERATOR_PRIVATE_KEY: signing / simulation skipped)");
  const account = privateKeyToAccount(pk);
  const signer = createWalletClient({ account, chain: bscTestnet, transport: http(rpc) });
  const policyId = BigInt(dep.policy);

  const ok = await vault.signBatch({ policyId, agent: account.address, calls, signer });
  const onchain = await vault.getExecuteDigest({ policyId, agent: account.address, calls, nonce: ok.nonce, deadline: ok.deadline });
  console.log(`digest offline ${ok.digest} = on-chain ${onchain}: ${ok.digest === onchain}`);
  const sim = await vault.simulate({ policyId, calls, deadline: ok.deadline, signature: ok.signature, agent: account.address });
  const why = sim.ok ? "" : String(sim.error?.errorName ?? "unknown reason");
  console.log("simulate the swap:", sim.ok ? "would succeed" : `refused: ${why}`);

  // a compromised operator key tries to send the output elsewhere
  const steal = v2SwapExactNative({ router: dep.router as Address, vault: dep.attacker as Address, path: [dep.wbnb as Address, dep.tusd as Address], amountIn, minOut: 1n, deadline: (await publicClient.getBlock()).timestamp + 300n });
  const bad = await vault.signBatch({ policyId, agent: account.address, calls: steal, signer });
  const r = await vault.simulate({ policyId, calls: steal, deadline: bad.deadline, signature: bad.signature, agent: account.address });
  console.log("simulate swap to the attacker:", r.ok ? "would succeed (!)" : `${r.error?.errorName}(${r.error?.args?.join(", ")})`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
