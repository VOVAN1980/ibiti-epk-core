// SDK v2: an opt-in vault upgrade driven entirely from TypeScript — schedule, watch, wait, execute.
// Runs on BSC Testnet or opBNB Testnet against the network's upgrade-demo vault (test networks: 5-minute delays,
// same code as mainnet): opts it into the current release (deployments/<network>/epk-release.json). Needs the
// demo vault's admin key named there (`adminKey`) in the environment or in ../.env. SENDS TRANSACTIONS.
//   npx tsx examples/v2-upgrade.ts          (BSC Testnet)
//   npx tsx examples/v2-upgrade.ts opbnb    (opBNB Testnet)
import { readFileSync } from "node:fs";
import { createPublicClient, createWalletClient, http, keccak256, toBytes, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { bscTestnet, opBNBTestnet } from "viem/chains";

import { EPKUpgrader, watchVault } from "../src/v2/index.js";

const opbnb = process.argv[2] === "opbnb";
const chain = opbnb ? opBNBTestnet : bscTestnet;
const demo = JSON.parse(
  readFileSync(`../deployments/${opbnb ? "opbnb" : "bsc"}-testnet/epk-release.json`, "utf8"),
) as Record<string, string>;
const vault = demo.upgradeVault as Address;
const release = demo.implementation as Address;
const salt = keccak256(toBytes(`EPK SDK v2 upgrade to ${demo.version}`));
const rpc = opbnb
  ? (process.env.OPBNB_TESTNET_RPC ?? "https://opbnb-testnet-rpc.bnbchain.org")
  : (process.env.BSC_TESTNET_RPC ?? "https://bsc-testnet-rpc.publicnode.com");

function envKey(name: string): Hex {
  if (process.env[name]) return process.env[name]!.trim() as Hex;
  const line = readFileSync("../.env", "utf8").split(/\r?\n/).find((l) => l.startsWith(name + "="));
  if (!line) throw new Error(`${name} missing in ../.env`);
  return line.slice(name.length + 1).trim() as Hex;
}

const t = () => new Date().toISOString().slice(11, 19) + " UTC";

async function main() {
  const publicClient = createPublicClient({ chain, transport: http(rpc) });
  const admin = createWalletClient({ account: privateKeyToAccount(envKey(demo.adminKey)), chain, transport: http(rpc) });
  const upgrader = new EPKUpgrader(vault, publicClient, admin);
  const registry = await upgrader.registry();
  const fromBlock = (await publicClient.getBlockNumber()) - 5n;

  console.log(`${t()}  vault ${vault} runs ${await upgrader.currentVersion()}; release window ${await registry.approvalDelay()} s`);
  console.log(`${t()}  status: ${(await upgrader.status(release, salt, fromBlock)).state}`);

  const stop = watchVault(publicClient, vault, (e) => {
    if (e.kind === "scheduled") console.log(`${t()}  [watch] scheduled ${e.call?.functionName} — "${e.label}" — ready at ${new Date(Number(e.readyAt) * 1000).toISOString().slice(11, 19)} UTC`);
    if (e.kind === "upgraded") console.log(`${t()}  [watch] Upgraded -> ${e.implementation}`);
  });

  const { hash, operationId } = await upgrader.schedule(release, salt);
  await publicClient.waitForTransactionReceipt({ hash });
  console.log(`${t()}  scheduled: tx ${hash}, operation ${operationId}`);

  for (;;) {
    const s = await upgrader.status(release, salt, fromBlock);
    if (s.state === "ready") break;
    if (s.state !== "waiting") throw new Error(`unexpected state ${s.state}`);
    console.log(`${t()}  waiting… executable at ${new Date(Number(s.executableAt) * 1000).toISOString().slice(11, 19)} UTC`);
    await new Promise((r) => setTimeout(r, 30_000));
  }
  const exec = await upgrader.execute(release, salt);
  await publicClient.waitForTransactionReceipt({ hash: exec });
  console.log(`${t()}  executed: tx ${exec}`);
  console.log(`${t()}  vault ${vault} now runs ${await upgrader.currentVersion()}`);
  await new Promise((r) => setTimeout(r, 6_000));
  stop();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
