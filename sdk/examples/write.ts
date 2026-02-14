import "dotenv/config";
import { createPublicClient, createWalletClient, http, keccak256 } from "viem";
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
  if (s.length !== 66) throw new Error(`Bad private key length (need 32 bytes hex): ${s.slice(0, 10)}...`);
  return s as `0x${string}`;
}
const rpcUrl = process.env.BSC_RPC_URL || process.env.RPC_URL || "https://data-seed-prebsc-1-s1.binance.org:8545";
const owner = privateKeyToAccount(normPk(req("OWNER_PRIVATE_KEY")));
const agent = privateKeyToAccount(normPk(req("AGENT_PRIVATE_KEY")));
const kernelAddr = req("EPKERNEL") as `0x${string}`;
const policyId = BigInt(req("POLICY_ID"));
const publicClient = createPublicClient({ chain: bscTestnet, transport: http(rpcUrl) });
const ownerWallet = createWalletClient({ chain: bscTestnet, transport: http(rpcUrl), account: owner });
const agentWallet = createWalletClient({ chain: bscTestnet, transport: http(rpcUrl), account: agent });
const kernel = { address: kernelAddr, abi: EPKernelAbi as any };
async function main() {
  console.log("=== Execute + Revoke Demo ===");
  console.log("chainId", await publicClient.getChainId());
  console.log("rpc", rpcUrl);
  console.log("kernel", kernelAddr);
  console.log("owner", owner.address);
  console.log("agent", agent.address);
  console.log("policyId", policyId.toString());
  // target + data (setX(123)) - берём target из .env
  const target = (process.env.MOCKTARGET || "").trim() as `0x${string}`;
  if (!target) throw new Error("Missing env: MOCKTARGET");
  const value = 0n;
  const data =
    ("0x4018d9aa" + "000000000000000000000000000000000000000000000000000000000000007b") as `0x${string}`; // setX(123)
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
  // nonce в контракте хранится в nonces(uint256) - фактически keyed от owner (как в Foundry smoke)
  const nonce = (await publicClient.readContract({
    ...kernel,
    functionName: "nonces",
    args: [owner.address as any],
  })) as bigint;
  // name/version читаем с контракта, чтобы не гадать
  const [name, version] = await Promise.all([
    publicClient.readContract({ ...kernel, functionName: "EIP712_NAME" as any }),
    publicClient.readContract({ ...kernel, functionName: "EIP712_VERSION" as any }),
  ]);
  const domain = {
    name,
    version,
    chainId: bscTestnet.id,
    verifyingContract: kernelAddr,
  };
  const types = {
    Execute: [
      { name: "policyId", type: "uint256" },
      { name: "target", type: "address" },
      { name: "value", type: "uint256" },
      { name: "dataHash", type: "bytes32" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  } as const;
  const message = {
    policyId,
    target,
    value,
    dataHash: keccak256(data),
    nonce,
    deadline,
  } as const;
  const signature = await ownerWallet.signTypedData({
    account: owner,
    domain,
    types,
    primaryType: "Execute",
    message: message as any,
  });
  console.log("nonce", nonce.toString());
  console.log("target", target);
  console.log("deadline", deadline.toString());
  console.log("signature", signature);
  // Agent выполняет execute
  const tx = await agentWallet.writeContract({
    ...kernel,
    functionName: "execute",
    args: [policyId, target, value, data, deadline, signature],
  });
  console.log("execute tx", tx);
  await publicClient.waitForTransactionReceipt({ hash: tx });
  // Revoke policy (owner)
  const revokeTx = await ownerWallet.writeContract({
    ...kernel,
    functionName: "setPolicyActive",
    args: [policyId, false],
  });
  console.log("revoke tx", revokeTx);
  await publicClient.waitForTransactionReceipt({ hash: revokeTx });
  console.log("DONE: revoked. Next execute should revert PolicyInactive().");
}
main().catch((e) => {
  console.error(e);
  process.exit(1);
});
