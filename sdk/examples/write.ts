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

async function main() {
  console.log("=== Execute + Security Demos ===");
  console.log("chainId", await publicClient.getChainId());
  console.log("rpc", rpcUrl);
  console.log("kernel", kernelAddr);
  console.log("owner", owner.address);
  console.log("agent", agent.address);
  console.log("policyId", policyId.toString());

  // target из .env
  const target = (process.env.MOCKTARGET || "").trim() as `0x${string}`;
  if (!target) throw new Error("Missing env: MOCKTARGET");

  const value = 0n;

  // setX(123): 0x4018d9aa + 32-byte uint(123)
  const goodData =
    ("0x4018d9aa" + "000000000000000000000000000000000000000000000000000000000000007b") as `0x${string}`;

  // плохой selector: x() = 0x0c55699c (ты получил через cast sig "x()")
  const badData = "0x0c55699c" as `0x${string}`;

  // name/version читаем с контракта
  const [name, version, chainId] = await Promise.all([
    publicClient.readContract({ ...kernel, functionName: "EIP712_NAME" as any }),
    publicClient.readContract({ ...kernel, functionName: "EIP712_VERSION" as any }),
    publicClient.getChainId(),
  ]);

  const domain = {
    name,
    version,
    chainId,
    verifyingContract: kernelAddr,
  };

  // helper: подписать под конкретные data + nonce
  async function signFor(data: `0x${string}`, nonce: bigint, deadline: bigint) {
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

    return { deadline, signature };
  }

  // nonce ДОЛЖЕН читаться по policyId (а не по owner.address)
  const nonce0 = (await publicClient.readContract({
    ...kernel,
    functionName: "nonces",
    args: [policyId],
  })) as bigint;

  console.log("nonce0", nonce0.toString());
  console.log("target", target);

  // 1) GOOD execute (should PASS)
  console.log("=== 1) GOOD execute: setX(123) ===");
  const dl1 = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const sig1 = await signFor(goodData, nonce0, dl1);

  const tx1 = await agentWallet.writeContract({
    ...kernel,
    functionName: "execute",
    args: [policyId, target, value, goodData, sig1.deadline, sig1.signature],
  });
  console.log("execute tx", tx1);
  await publicClient.waitForTransactionReceipt({ hash: tx1 });

  // 2) Replay same signature/data (should NonceTooLow)
  console.log("=== 2) REPLAY test (expect NonceTooLow) ===");
  try {
    await agentWallet.writeContract({
      ...kernel,
      functionName: "execute",
      args: [policyId, target, value, goodData, sig1.deadline, sig1.signature],
    });
    console.log("UNEXPECTED: replay executed");
  } catch (e) {
    console.log("OK: replay reverted");
  }

  // 3) CallNotAllowed via bad selector x() (must be signed with badData!)
  console.log("=== 3) CallNotAllowed test (expect CallNotAllowed) ===");
  const nonceNow = (await publicClient.readContract({
    ...kernel,
    functionName: "nonces",
    args: [policyId],
  })) as bigint;

  const dlBad = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const sigBad = await signFor(badData, nonceNow, dlBad);

  try {
    await agentWallet.writeContract({
      ...kernel,
      functionName: "execute",
      args: [policyId, target, value, badData, sigBad.deadline, sigBad.signature],
    });
    console.log("UNEXPECTED: bad call executed");
  } catch (e) {
    console.log("OK: bad call reverted (should be CallNotAllowed)");
  }

  // 4) emergencyNonceBump kills queued signature
  console.log("=== 4) emergencyNonceBump test (kill queued sig) ===");
  const nonceBeforeBump = (await publicClient.readContract({
    ...kernel,
    functionName: "nonces",
    args: [policyId],
  })) as bigint;

  // queued sig (do NOT send yet)
  const dlQueued = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const queued = await signFor(goodData, nonceBeforeBump, dlQueued);

  const bumpTx = await ownerWallet.writeContract({
    ...kernel,
    functionName: "emergencyNonceBump",
    args: [policyId, nonceBeforeBump + 100n],
  });
  console.log("nonce bump tx", bumpTx);
  await publicClient.waitForTransactionReceipt({ hash: bumpTx });

  try {
    await agentWallet.writeContract({
      ...kernel,
      functionName: "execute",
      args: [policyId, target, value, goodData, queued.deadline, queued.signature],
    });
    console.log("UNEXPECTED: queued sig executed");
  } catch (e) {
    console.log("OK: queued sig reverted (expect NonceTooLow)");
  }

  // 5) Revoke policy + verify PolicyInactive
  console.log("=== 5) Revoke policy + PolicyInactive check ===");
  const revokeTx = await ownerWallet.writeContract({
    ...kernel,
    functionName: "setPolicyActive",
    args: [policyId, false],
  });
  console.log("revoke tx", revokeTx);
  await publicClient.waitForTransactionReceipt({ hash: revokeTx });

  const nonceAfterRevoke = (await publicClient.readContract({
    ...kernel,
    functionName: "nonces",
    args: [policyId],
  })) as bigint;

  const dlAfter = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const sigAfter = await signFor(goodData, nonceAfterRevoke, dlAfter);

  try {
    await agentWallet.writeContract({
      ...kernel,
      functionName: "execute",
      args: [policyId, target, value, goodData, sigAfter.deadline, sigAfter.signature],
    });
    console.log("UNEXPECTED: executed after revoke");
  } catch (e) {
    console.log("OK: PolicyInactive reverted");
  }

  console.log("DONE.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});