import "dotenv/config";
import { createPublicClient, http } from "viem";
import { bscTestnet } from "viem/chains";
import { createEPKContracts } from "../src/kernel";
const rpcUrl = process.env.BSC_RPC_URL || process.env.RPC_URL;
if (!rpcUrl)
    throw new Error("Set BSC_RPC_URL or RPC_URL");
const EPKERNEL = process.env.EPKERNEL;
const publicClient = createPublicClient({
    chain: bscTestnet,
    transport: http(rpcUrl),
});
const c = createEPKContracts({
    publicClient,
    addresses: {
        ...(EPKERNEL ? { EPKernel: EPKERNEL } : {}),
    },
});
console.log("chainId", await publicClient.getChainId());
console.log("rpc", rpcUrl);
console.log("EPKernel", c.EPKernel?.address ?? "not set");
