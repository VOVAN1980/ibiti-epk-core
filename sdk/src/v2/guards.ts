import { type Address, type Hex, type PublicClient, encodeFunctionData, erc20Abi, parseAbi } from "viem";

import { dexGuardAbi } from "./abi/dexGuardAbi.js";
import { threatFeedGuardAbi } from "./abi/threatFeedGuardAbi.js";
import type { Call } from "./vault.js";

/** Uniswap V2 / PancakeSwap V2 router functions DexGuard supports. */
export const v2RouterAbi = parseAbi([
  "function getAmountsOut(uint256 amountIn, address[] path) view returns (uint256[])",
  "function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline) returns (uint256[])",
  "function swapTokensForExactTokens(uint256 amountOut, uint256 amountInMax, address[] path, address to, uint256 deadline) returns (uint256[])",
  "function swapExactETHForTokens(uint256 amountOutMin, address[] path, address to, uint256 deadline) payable returns (uint256[])",
  "function swapETHForExactTokens(uint256 amountOut, address[] path, address to, uint256 deadline) payable returns (uint256[])",
  "function swapExactTokensForETH(uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline) returns (uint256[])",
  "function swapTokensForExactETH(uint256 amountOut, uint256 amountInMax, address[] path, address to, uint256 deadline) returns (uint256[])",
]);

/** Read-only helper for a deployed DexGuard: the exact limits it will enforce right now. */
export class DexGuardClient {
  constructor(
    readonly address: Address,
    readonly publicClient: PublicClient,
  ) {}

  private read(functionName: string, args: readonly unknown[] = []) {
    return this.publicClient.readContract({
      address: this.address,
      abi: dexGuardAbi,
      functionName: functionName as never,
      args: args as never,
    }) as Promise<unknown>;
  }

  /** Smallest output an exact-input swap may accept now (Chainlink fair value minus the guard's slippage). */
  async minimumOut(tokenIn: Address, tokenOut: Address, amountIn: bigint): Promise<bigint> {
    return (await this.read("minimumOut", [tokenIn, tokenOut, amountIn])) as bigint;
  }

  /** Largest input an exact-output swap may pay now. */
  async maximumIn(tokenIn: Address, tokenOut: Address, amountOut: bigint): Promise<bigint> {
    return (await this.read("maximumIn", [tokenIn, tokenOut, amountOut])) as bigint;
  }

  /** Fair price of a listed token, 18 decimals of the feeds' quote currency (reverts if stale or out of bounds). */
  async price(token: Address): Promise<bigint> {
    return (await this.read("price", [token])) as bigint;
  }

  async maxSlippageBps(): Promise<bigint> {
    return (await this.read("maxSlippageBps")) as bigint;
  }

  /** Longest swap deadline the guard accepts, in seconds from now. */
  async maxDeadline(): Promise<bigint> {
    return (await this.read("maxDeadline")) as bigint;
  }

  async routers(): Promise<readonly Address[]> {
    return (await this.read("routers")) as readonly Address[];
  }

  async tokens(): Promise<readonly Address[]> {
    return (await this.read("tokens")) as readonly Address[];
  }
}

/** Is any address in this call on the ThreatFeed V2 blocklist? (the same scan the guard runs) */
export async function isCallBlocked(publicClient: PublicClient, feed: Address, target: Address, data: Hex) {
  return publicClient.readContract({ address: feed, abi: threatFeedGuardAbi, functionName: "isCallBlocked", args: [target, data] });
}

const approve = (token: Address, spender: Address, amount: bigint): Call => ({
  target: token,
  value: 0n,
  data: encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [spender, amount] }),
});

/**
 * Batch for an exact-input token swap on a V2 router: approve → swap → allowance reset.
 * The output always goes to the vault (DexGuard rejects anything else).
 */
export function v2SwapExactTokens(args: {
  router: Address;
  vault: Address;
  path: readonly Address[];
  amountIn: bigint;
  minOut: bigint;
  deadline: bigint;
}): Call[] {
  const tokenIn = args.path[0];
  return [
    approve(tokenIn, args.router, args.amountIn),
    {
      target: args.router,
      value: 0n,
      data: encodeFunctionData({
        abi: v2RouterAbi,
        functionName: "swapExactTokensForTokens",
        args: [args.amountIn, args.minOut, [...args.path], args.vault, args.deadline],
      }),
    },
    approve(tokenIn, args.router, 0n),
  ];
}

/** Batch for an exact-input swap paying native coin (BNB / ETH); `path[0]` must be the wrapped native token. */
export function v2SwapExactNative(args: {
  router: Address;
  vault: Address;
  path: readonly Address[];
  amountIn: bigint;
  minOut: bigint;
  deadline: bigint;
}): Call[] {
  return [
    {
      target: args.router,
      value: args.amountIn,
      data: encodeFunctionData({
        abi: v2RouterAbi,
        functionName: "swapExactETHForTokens",
        args: [args.minOut, [...args.path], args.vault, args.deadline],
      }),
    },
  ];
}

/** Batch selling tokens for native coin (`path` ends at the wrapped native token): approve → swap → reset. */
export function v2SwapExactTokensForNative(args: {
  router: Address;
  vault: Address;
  path: readonly Address[];
  amountIn: bigint;
  minOut: bigint;
  deadline: bigint;
}): Call[] {
  const tokenIn = args.path[0];
  return [
    approve(tokenIn, args.router, args.amountIn),
    {
      target: args.router,
      value: 0n,
      data: encodeFunctionData({
        abi: v2RouterAbi,
        functionName: "swapExactTokensForETH",
        args: [args.amountIn, args.minOut, [...args.path], args.vault, args.deadline],
      }),
    },
    approve(tokenIn, args.router, 0n),
  ];
}

/**
 * Plan a guarded exact-input swap: reads the guard's minimum and the router's quote and picks a minimum
 * output that both the pool can deliver and the guard accepts. Throws a readable error when the pool
 * pays less than the guard allows — the trade would be refused on-chain anyway (e.g. a manipulated or
 * stale pool), so a bot can skip it without paying gas.
 */
export async function planGuardedSwap(args: {
  publicClient: PublicClient;
  guard: Address;
  router: Address;
  vault: Address;
  path: readonly Address[];
  amountIn: bigint;
  /** native coin in? then path[0] must be the wrapped native token */
  native?: boolean;
  /** how much below the quote the minimum may be, to absorb small moves (default 10 bps) */
  bufferBps?: bigint;
  /** swap deadline in seconds from now (default: the guard's maximum minus 30 s) */
  deadlineIn?: bigint;
}): Promise<{ calls: Call[]; minOut: bigint; quote: bigint; guardMinimum: bigint; deadline: bigint }> {
  const g = new DexGuardClient(args.guard, args.publicClient);
  const tokenIn = args.path[0];
  const tokenOut = args.path[args.path.length - 1];
  const [guardMinimum, amounts, maxDl] = await Promise.all([
    g.minimumOut(tokenIn, tokenOut, args.amountIn),
    args.publicClient.readContract({ address: args.router, abi: v2RouterAbi, functionName: "getAmountsOut", args: [args.amountIn, [...args.path]] }),
    g.maxDeadline(),
  ]);
  const quote = amounts[amounts.length - 1];
  const minOut = (quote * (10_000n - (args.bufferBps ?? 10n))) / 10_000n;
  if (minOut < guardMinimum) {
    throw new Error(
      `pool pays ${quote}, guard requires at least ${guardMinimum}: the trade would be refused (PriceTooLow) — pool is off the Chainlink price`,
    );
  }
  const block = await args.publicClient.getBlock();
  const deadline = block.timestamp + (args.deadlineIn ?? maxDl - 30n);
  const calls = args.native
    ? v2SwapExactNative({ router: args.router, vault: args.vault, path: args.path, amountIn: args.amountIn, minOut, deadline })
    : v2SwapExactTokens({ router: args.router, vault: args.vault, path: args.path, amountIn: args.amountIn, minOut, deadline });
  return { calls, minOut, quote, guardMinimum, deadline };
}
