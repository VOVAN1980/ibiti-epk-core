import { type Account, type Address, type Chain, type Transport, type WalletClient } from "viem";
import type { AnyPublicClient } from "./client.js";

import { dexGuardAbi } from "./abi/dexGuardAbi.js";
import { threatFeedGuardAbi } from "./abi/threatFeedGuardAbi.js";
import { compositeGuardAbi } from "./abi/compositeGuardAbi.js";
import { dexGuardBytecode } from "./abi/dexGuardBytecode.js";
import { threatFeedGuardBytecode } from "./abi/threatFeedGuardBytecode.js";
import { compositeGuardBytecode } from "./abi/compositeGuardBytecode.js";

type Wallet = WalletClient<Transport, Chain, Account>;

async function deployed(publicClient: AnyPublicClient, hash: `0x${string}`): Promise<Address> {
  const rc = await publicClient.waitForTransactionReceipt({ hash });
  if (rc.status !== "success" || !rc.contractAddress) throw new Error(`deployment failed (tx ${hash})`);
  return rc.contractAddress;
}

export type DexGuardConfig = {
  /** wrapped native token (prices native-coin swaps), or the zero address to refuse native swaps */
  wrappedNative: Address;
  /** e.g. 100 = 1 % (max 1000) */
  maxSlippageBps: bigint;
  /** longest swap deadline in seconds from now (30 s .. 1 day) */
  maxDeadline: bigint;
  routers: { router: Address; kind: "V2" | "V3" }[];
  /** every token a swap may touch, each with a Chainlink-compatible feed (all feeds in the same quote currency) */
  tokens: { token: Address; feed: Address; maxAge: number; maxAmountIn: bigint; minPrice: bigint; maxPrice: bigint }[];
};

/** Deploy your own DexGuard. Its rules are fixed forever; new rules = a new guard switched in through the vault's timelock. */
export async function deployDexGuard(walletClient: Wallet, publicClient: AnyPublicClient, cfg: DexGuardConfig): Promise<Address> {
  const hash = await walletClient.deployContract({
    abi: dexGuardAbi,
    bytecode: dexGuardBytecode,
    account: walletClient.account,
    chain: walletClient.chain,
    args: [
      cfg.wrappedNative,
      cfg.maxSlippageBps,
      cfg.maxDeadline,
      cfg.routers.map((r) => ({ router: r.router, kind: r.kind === "V2" ? 1 : 2 })),
      cfg.tokens,
    ],
  });
  return deployed(publicClient, hash);
}

/** Deploy a ThreatFeed V2 blocklist you operate: instant blocking, unblocking after `unblockDelay` (>= 1 hour). */
export async function deployThreatFeed(walletClient: Wallet, publicClient: AnyPublicClient, cfg: { owner: Address; unblockDelay: bigint }): Promise<Address> {
  const hash = await walletClient.deployContract({
    abi: threatFeedGuardAbi,
    bytecode: threatFeedGuardBytecode,
    account: walletClient.account,
    chain: walletClient.chain,
    args: [cfg.owner, cfg.unblockDelay],
  });
  return deployed(publicClient, hash);
}

/** Combine guards (all must pass). `legacy[i] = true` for a validator that only implements `validate`. */
export async function deployCompositeGuard(
  walletClient: Wallet,
  publicClient: AnyPublicClient,
  cfg: { guards: Address[]; legacy?: boolean[] },
): Promise<Address> {
  const hash = await walletClient.deployContract({
    abi: compositeGuardAbi,
    bytecode: compositeGuardBytecode,
    account: walletClient.account,
    chain: walletClient.chain,
    args: [cfg.guards, cfg.legacy ?? cfg.guards.map(() => false)],
  });
  return deployed(publicClient, hash);
}
