import { createPublicClient, http } from "viem";
import { bscTestnet } from "viem/chains";
import { createEPKContracts } from "../src/kernel";

function req(name: string) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env: ${name}`);
  return v;
}

const rpcUrl =
  process.env.BSC_RPC_URL ||
  process.env.RPC_URL ||
  "https://data-seed-prebsc-1-s1.binance.org:8545";

const publicClient = createPublicClient({ chain: bscTestnet, transport: http(rpcUrl) });

const addresses = {
  EPKernel: req("EPKERNEL"),
  CompositeValidator: process.env.COMPOSITE_VALIDATOR,
  TargetSelectorGuard: process.env.TARGET_SELECTOR_GUARD,
  SpendLimitValidator: process.env.SPEND_LIMIT_VALIDATOR,
  ThreatFeedBlocklistValidator: process.env.THREATFEED_BLOCKLIST_VALIDATOR,
} as const;

const c = createEPKContracts({ publicClient, addresses: addresses as any });

console.log("chainId", await publicClient.getChainId());
console.log("rpc", rpcUrl);
console.log("EPKernel", c.EPKernel?.address ?? addresses.EPKernel);
console.log("CompositeValidator", c.CompositeValidator?.address ?? addresses.CompositeValidator ?? "-");
console.log("TargetSelectorGuard", c.TargetSelectorGuard?.address ?? addresses.TargetSelectorGuard ?? "-");
console.log("SpendLimitValidator", c.SpendLimitValidator?.address ?? addresses.SpendLimitValidator ?? "-");
console.log("ThreatFeedBlocklistValidator", c.ThreatFeedBlocklistValidator?.address ?? addresses.ThreatFeedBlocklistValidator ?? "-");

