import "dotenv/config";
import { createPublicClient, createWalletClient, http, parseEventLogs, stringToHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { bscTestnet } from "viem/chains";
import EPKernelAbi from "../src/abi/EPKernel.abi.json" with { type: "json" };
function req(name: string) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env: ${name}`);
  return v;
}
function normPk(v: string) {
  const s = v.startsWith("0x") ? v : `0x${v}`;
  if (s.length !== 66) throw new Error(`Bad private key length: ${s.slice(0, 10)}...`);
  return s as `0x${string}`;
}
const rpcUrl = process.env.BSC_RPC_URL || process.env.RPC_URL || "https://data-seed-prebsc-1-s1.binance.org:8545";
const owner = privateKeyToAccount(normPk(req("OWNER_PRIVATE_KEY")));
const agent = privateKeyToAccount(normPk(req("AGENT_PRIVATE_KEY")));
const publicClient = createPublicClient({ chain: bscTestnet, transport: http(rpcUrl) });
const ownerWallet = createWalletClient({ chain: bscTestnet, transport: http(rpcUrl), account: owner });
const kernel = { address: req("EPKERNEL") as `0x${string}`, abi: EPKernelAbi as any };
// target для allow-list
const target = req("MOCKTARGET") as `0x${string}`;
// selector setX(uint256) = 0x4018d9aa (у тебя он уже светился в data)
const selector = "0x4018d9aa" as `0x${string}`;
// policy params (можешь менять)
const now = Math.floor(Date.now() / 1000);
const validUntil = BigInt(now + 3600 * 24 * 30);      // 30 дней
const maxValuePerCall = 0n;                          // 0 = только calls без value
const validator = "0x0000000000000000000000000000000000000000" as `0x${string}`; // без валидатора
// agent validUntil (можешь = policy)
const validUntilAgent = BigInt(now + 3600 * 24 * 30);
console.log("rpc", rpcUrl);
console.log("kernel", kernel.address);
console.log("owner", owner.address);
console.log("agent", agent.address);
console.log("target", target);
const ownerBal = await publicClient.getBalance({ address: owner.address });
const agentBal = await publicClient.getBalance({ address: agent.address });
console.log("ownerBalance", ownerBal.toString());
console.log("agentBalance", agentBal.toString());
if (ownerBal === 0n) throw new Error("Owner has 0 balance for gas. Fund owner on BSC testnet.");
if (agentBal === 0n) throw new Error("Agent has 0 balance for gas. Fund agent on BSC testnet.");
const tx1 = await ownerWallet.writeContract({
  ...kernel,
  functionName: "createPolicy",
  args: [validUntil, maxValuePerCall, validator],
});
console.log("createPolicy tx", tx1);
const r1 = await publicClient.waitForTransactionReceipt({ hash: tx1 });
const created = parseEventLogs({
  abi: EPKernelAbi as any,
  logs: r1.logs,
  eventName: "PolicyCreated",
});
const policyId = (created[0] as any).args.policyId as bigint;
console.log("policyId", policyId.toString());
const tx2 = await ownerWallet.writeContract({
  ...kernel,
  functionName: "setAgent",
  args: [policyId, agent.address, true, validUntilAgent],
});
console.log("setAgent tx", tx2);
await publicClient.waitForTransactionReceipt({ hash: tx2 });
const tx3 = await ownerWallet.writeContract({
  ...kernel,
  functionName: "setCall",
  args: [policyId, target, selector, true],
});
console.log("setCall tx", tx3);
await publicClient.waitForTransactionReceipt({ hash: tx3 });
console.log("");
console.log("DONE. Put this into sdk/.env:");
console.log(`POLICY_ID=${policyId.toString()}`);
