import type { PublicClient } from "viem";

/**
 * Any viem public client: with or without a chain, batching, a custom RPC schema or token formatters.
 * (viem's default `PublicClient` type rejects many real clients, e.g. one created with `chain: bscTestnet`.)
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type AnyPublicClient = PublicClient<any, any, any, any, any>;
