// EPK SDK v2 quickstart for integrators: your own vault on BSC Testnet in a few minutes, from zero.
// You need ONE funded testnet key (tBNB from a faucet). Everything else is created here.
//
//   cp .env.example .env   # put a SEPARATE testnet key into ADMIN_PRIVATE_KEY (never on the command line:
//   npx tsx examples/v2-quickstart.ts   # it would end up in your shell history)
//
// The guardian and recovery keys it creates are thrown away: nobody can pause or recover this demo vault
// later. For a real vault, generate them on separate devices and keep them.
//
// What it does (all real transactions on BSC Testnet, ~0.005 tBNB):
//   1. creates YOUR vault through the public EPK factory (you are its admin)
//   2. configures it: native-coin limit, your treasury as the only payee, a policy for your bot
//   3. finalizes setup (from now on loosening changes need the 1-hour timelock) and deposits 0.003 tBNB
//   4. your bot pays the treasury on its own
//   5. a "stolen" bot key tries to pay a stranger and to exceed the limit — the SDK shows the vault's answer
//      before any gas is spent
import { createPublicClient, createWalletClient, http, parseEther, formatEther, keccak256, toBytes, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { bscTestnet } from "viem/chains";

import {
  networks,
  EPKFactoryClient,
  VaultAdmin,
  vaultActions,
  EPKVaultClient,
  NATIVE,
  NATIVE_TRANSFER,
  explainEpkError,
  findRevertData,
} from "../src/v2/index.js";

const rpc = process.env.BSC_TESTNET_RPC ?? "https://bsc-testnet-rpc.publicnode.com";
try {
  process.loadEnvFile?.(".env"); // sdk/.env, git-ignored (Node 20.12+)
} catch {
  /* no .env: use the environment */
}
const adminKey = process.env.ADMIN_PRIVATE_KEY as Hex | undefined;
if (!adminKey) throw new Error("put ADMIN_PRIVATE_KEY (a funded BSC Testnet key) into sdk/.env");

const t = () => new Date().toISOString().slice(11, 19);
const log = (s: string) => console.log(`${t()}  ${s}`);

async function main() {
  const net = networks.bscTestnet;
  const publicClient = createPublicClient({ chain: bscTestnet, transport: http(rpc) });
  const admin = createWalletClient({ account: privateKeyToAccount(adminKey!), chain: bscTestnet, transport: http(rpc) });

  // the other roles — in production: separate devices / services you control
  const guardians = [privateKeyToAccount(generatePrivateKey()).address, privateKeyToAccount(generatePrivateKey()).address];
  const recovery = privateKeyToAccount(generatePrivateKey()).address; // a cold key
  const treasury = privateKeyToAccount(generatePrivateKey()).address; // where the bot may pay
  const botAccount = privateKeyToAccount(generatePrivateKey()); // your bot's hot key
  const bot = createWalletClient({ account: botAccount, chain: bscTestnet, transport: http(rpc) });
  const stranger = privateKeyToAccount(generatePrivateKey()).address;

  // 1. create the vault
  const factory = new EPKFactoryClient(net.epk.factory, publicClient, admin);
  const salt = keccak256(toBytes(`quickstart ${Date.now()}`));
  const predicted = await factory.predictVault({ admin: admin.account.address, guardians, delay: 3600n, recovery, salt });
  const { vault } = await factory.createVault({ guardians, delay: 3600n, recovery, salt });
  log(`1. vault created: ${vault} (predicted ${predicted === vault ? "correctly" : "WRONG"})`);

  // 2. configure during setup (takes effect at once)
  const adminTools = new VaultAdmin(vault, publicClient, admin);
  const created = await adminTools.apply([
    vaultActions.setAsset(NATIVE, parseEther("0.002"), 86_400), // at most 0.002 tBNB per day leaves the vault
    vaultActions.addDestination(treasury), // the only address money may go to
    vaultActions.createPolicy(botAccount.address, 0, parseEther("0.001")), // bot policy, ≤ 0.001 per call
  ]);
  const policyId = created.policyIds[0];
  await adminTools.apply([
    vaultActions.setAgent(policyId, botAccount.address), // the bot submits its own batches
    vaultActions.setCall(policyId, treasury, NATIVE_TRANSFER), // it may only send native coin to the treasury
  ]);
  log(`2. configured: limit 0.002 tBNB/day, payee ${treasury.slice(0, 10)}…, policy #${policyId} for the bot`);

  // 3. go live and fund
  await adminTools.finalizeSetup();
  // more than the daily limit, so the limit — not the balance — is what stops a thief
  await publicClient.waitForTransactionReceipt({ hash: await admin.sendTransaction({ to: vault, value: parseEther("0.003") }) });
  await publicClient.waitForTransactionReceipt({ hash: await admin.sendTransaction({ to: botAccount.address, value: parseEther("0.0005") }) }); // gas for the bot
  log(`3. setup finalized; vault holds ${formatEther(await publicClient.getBalance({ address: vault }))} tBNB`);

  // 4. the bot pays the treasury on its own
  const asBot = new EPKVaultClient({ address: vault, publicClient, walletClient: bot });
  const pay = [{ target: treasury, value: parseEther("0.0005"), data: "0x" as Hex }];
  const s1 = await asBot.signBatch({ policyId, agent: botAccount.address, calls: pay, signer: bot });
  const tx = await asBot.execute({ policyId, calls: pay, deadline: s1.deadline, signature: s1.signature });
  await publicClient.waitForTransactionReceipt({ hash: tx });
  log(`4. bot paid 0.0005 tBNB to the treasury: tx ${tx}`);
  log(`   left today: ${formatEther(await asBot.availableToSpend(NATIVE))} tBNB`);

  // 5. the bot key is stolen: what the vault answers (simulated — no gas spent)
  const steal = [{ target: stranger, value: parseEther("0.0005"), data: "0x" as Hex }];
  const s2 = await asBot.signBatch({ policyId, agent: botAccount.address, calls: steal, signer: bot });
  const r2 = await asBot.simulate({ policyId, calls: steal, deadline: s2.deadline, signature: s2.signature, agent: botAccount.address });
  log(`5a. stolen key pays a stranger -> ${r2.ok ? "WOULD SUCCEED (!)" : explainEpkError(findRevertData(r2.raw) ?? "0x")}`);

  const drain = [
    { target: treasury, value: parseEther("0.001"), data: "0x" as Hex },
    { target: treasury, value: parseEther("0.001"), data: "0x" as Hex },
  ];
  const s3 = await asBot.signBatch({ policyId, agent: botAccount.address, calls: drain, signer: bot });
  const r3 = await asBot.simulate({ policyId, calls: drain, deadline: s3.deadline, signature: s3.signature, agent: botAccount.address });
  log(`5b. stolen key tries to take more than today's limit -> ${r3.ok ? "WOULD SUCCEED (!)" : explainEpkError(findRevertData(r3.raw) ?? "0x")}`);

  log(`done. Your vault: https://testnet.bscscan.com/address/${vault}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
