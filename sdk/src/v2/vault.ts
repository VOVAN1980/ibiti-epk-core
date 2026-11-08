import {
  type Account,
  type Address,
  type Chain,
  type Hex,
  type Transport,
  type WalletClient,
  decodeErrorResult,
  encodeAbiParameters,
  hashTypedData,
  keccak256,
} from "viem";
import type { AnyPublicClient } from "./client.js";

import { epkVaultAbi } from "./abi/epkVaultAbi.js";
import { dexGuardAbi } from "./abi/dexGuardAbi.js";
import { threatFeedGuardAbi } from "./abi/threatFeedGuardAbi.js";
import { compositeGuardAbi } from "./abi/compositeGuardAbi.js";

/** One call of a batch the vault executes. `value` is native coin sent with the call. */
export type Call = { target: Address; value: bigint; data: Hex };

/** Native coin, as the vault names it in limits and budgets. */
export const NATIVE: Address = "0x0000000000000000000000000000000000000000";

/** Sessions get ids from 2^128 upward; ordinary policies are below. */
export const SESSION_ID_BASE = 1n << 128n;

/** EIP-712 types of `EPKVault.execute` — identical to the contract's `_EXECUTE_TYPEHASH` / `_CALL_TYPEHASH`. */
export const executeTypes = {
  Call: [
    { name: "target", type: "address" },
    { name: "value", type: "uint256" },
    { name: "data", type: "bytes" },
  ],
  Execute: [
    { name: "policyId", type: "uint256" },
    { name: "agent", type: "address" },
    { name: "calls", type: "Call[]" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

export type ExecuteMessage = {
  /** policy id, or session id (>= SESSION_ID_BASE) */
  policyId: bigint;
  /** the address that will submit `execute` (the signature binds it) */
  agent: Address;
  calls: readonly Call[];
  nonce: bigint;
  deadline: bigint;
};

/** Typed data a policy / session key signs for one batch. */
export function executeTypedData(chainId: number, vault: Address, message: ExecuteMessage) {
  return {
    domain: { name: "EPK Vault", version: "2", chainId, verifyingContract: vault },
    types: executeTypes,
    primaryType: "Execute" as const,
    message: { ...message, calls: [...message.calls] },
  };
}

/** The digest `EPKVault.getExecuteDigest` returns, computed offline. */
export function executeDigest(chainId: number, vault: Address, message: ExecuteMessage): Hex {
  return hashTypedData(executeTypedData(chainId, vault, message));
}

/** Operation id of a timelocked call: keccak256(abi.encode(data, salt)), as `EPKVault.hashOperation`. */
export function hashOperation(data: Hex, salt: Hex): Hex {
  return keccak256(encodeAbiParameters([{ type: "bytes" }, { type: "bytes32" }], [data, salt]));
}

/** Every custom error a vault batch can revert with: the vault's own and the guards' (they bubble up). */
export const epkErrorsAbi = [...epkVaultAbi, ...dexGuardAbi, ...threatFeedGuardAbi, ...compositeGuardAbi].filter(
  (x) => x.type === "error",
);

/** Decode revert data from a vault batch into `{ errorName, args }`, or `undefined` if unknown. */
export function decodeEpkError(data: Hex) {
  try {
    return decodeErrorResult({ abi: epkErrorsAbi, data });
  } catch {
    return undefined;
  }
}

export type VaultClientOptions = {
  address: Address;
  publicClient: AnyPublicClient;
  walletClient?: WalletClient<Transport, Chain, Account>;
};

/**
 * Thin, typed client for one EPKVault (2.0.x and 2.1.x).
 * Reads limits and budgets, signs and submits batches, opens sessions, and drives the timelock.
 */
export class EPKVaultClient {
  readonly address: Address;
  readonly publicClient: AnyPublicClient;
  readonly walletClient?: WalletClient<Transport, Chain, Account>;

  constructor(opts: VaultClientOptions) {
    this.address = opts.address;
    this.publicClient = opts.publicClient;
    this.walletClient = opts.walletClient;
  }

  private read<F extends string>(functionName: F, args: readonly unknown[] = []) {
    return this.publicClient.readContract({
      address: this.address,
      abi: epkVaultAbi,
      functionName: functionName as never,
      args: args as never,
    }) as Promise<unknown>;
  }

  private wallet() {
    if (!this.walletClient) throw new Error("EPKVaultClient: a walletClient is needed to send transactions");
    return this.walletClient;
  }

  // ---------------------------------------------------------------- reads

  /** major * 10_000 + minor * 100 + patch, e.g. 20100 = 2.1.0 */
  async version(): Promise<number> {
    return Number(await this.read("vaultVersion"));
  }

  async nonce(policyId: bigint): Promise<bigint> {
    return (await this.read("nonces", [policyId])) as bigint;
  }

  /** What the whole vault may still send of `token` in the current window (NATIVE for native coin). */
  async availableToSpend(token: Address): Promise<bigint> {
    return (await this.read("availableToSpend", [token])) as bigint;
  }

  /** What one session may still send of `token` in the current window. */
  async budgetAvailable(sessionId: bigint, token: Address): Promise<bigint> {
    return (await this.read("budgetAvailable", [sessionId, token])) as bigint;
  }

  async paused(): Promise<boolean> {
    return (await this.read("paused")) as boolean;
  }

  async isDestination(account: Address): Promise<boolean> {
    return (await this.read("isDestination", [account])) as boolean;
  }

  async trackedAssets(): Promise<readonly Address[]> {
    return (await this.read("trackedAssets")) as readonly Address[];
  }

  /** Guard of a session envelope (vault 2.1.0+; address(0) = none). */
  async envelopeGuard(envelopeId: bigint): Promise<Address> {
    return (await this.read("envelopeGuard", [envelopeId])) as Address;
  }

  /** The digest as the vault itself computes it (one RPC call; useful to cross-check `executeDigest`). */
  async getExecuteDigest(message: ExecuteMessage): Promise<Hex> {
    return (await this.read("getExecuteDigest", [
      message.policyId,
      message.agent,
      [...message.calls],
      message.nonce,
      message.deadline,
    ])) as Hex;
  }

  // ---------------------------------------------------------------- batches

  /**
   * Sign a batch with the policy / session key held by `signer` (a viem Account or wallet).
   * Reads the current nonce unless given; the deadline defaults to one hour from now.
   * The signature is bound to the signer's chain; if the public client is on another chain this throws
   * (a wrong or lying RPC must not make you sign for a different network).
   */
  async signBatch(args: {
    policyId: bigint;
    agent: Address;
    calls: readonly Call[];
    signer: WalletClient<Transport, Chain, Account>;
    nonce?: bigint;
    deadline?: bigint;
  }): Promise<{ signature: Hex; nonce: bigint; deadline: bigint; digest: Hex }> {
    const rpcChainId = await this.publicClient.getChainId();
    const signerChainId = args.signer.chain?.id;
    if (signerChainId !== undefined && signerChainId !== rpcChainId) {
      throw new Error(`signBatch: the signer is on chain ${signerChainId} but the public client is on chain ${rpcChainId}`);
    }
    const chainId = signerChainId ?? rpcChainId;
    const nonce = args.nonce ?? (await this.nonce(args.policyId));
    const deadline = args.deadline ?? BigInt(Math.floor(Date.now() / 1000) + 3600);
    const message: ExecuteMessage = { policyId: args.policyId, agent: args.agent, calls: args.calls, nonce, deadline };
    const typed = executeTypedData(chainId, this.address, message);
    const signature = await args.signer.signTypedData({ account: args.signer.account, ...typed });
    return { signature, nonce, deadline, digest: hashTypedData(typed) };
  }

  /**
   * Dry-run a signed batch from the agent's address. Returns `{ ok: true }` or the decoded EPK error,
   * so a bot can see e.g. `PriceTooLow` or `BudgetExceeded` before paying gas.
   */
  async simulate(args: {
    policyId: bigint;
    calls: readonly Call[];
    deadline: bigint;
    signature: Hex;
    coSignature?: Hex;
    agent: Address;
  }): Promise<{ ok: true } | { ok: false; error?: ReturnType<typeof decodeEpkError>; raw: unknown }> {
    try {
      await this.publicClient.simulateContract({
        address: this.address,
        abi: epkVaultAbi,
        functionName: "execute",
        args: [args.policyId, [...args.calls], args.deadline, args.signature, args.coSignature ?? "0x"],
        account: args.agent,
      });
      return { ok: true };
    } catch (e) {
      const data = findRevertData(e);
      return { ok: false, error: data ? decodeEpkError(data) : undefined, raw: e };
    }
  }

  /** Submit a signed batch (the wallet must be the `agent` the batch was signed for). */
  async execute(args: {
    policyId: bigint;
    calls: readonly Call[];
    deadline: bigint;
    signature: Hex;
    coSignature?: Hex;
  }): Promise<Hex> {
    const w = this.wallet();
    return w.writeContract({
      address: this.address,
      abi: epkVaultAbi,
      functionName: "execute",
      args: [args.policyId, [...args.calls], args.deadline, args.signature, args.coSignature ?? "0x"],
      account: w.account,
      chain: w.chain,
    });
  }

  // ---------------------------------------------------------------- sessions

  /** Open an AI-agent session inside an envelope (only the session manager can). Returns the tx hash. */
  async openSession(args: { envelopeId: bigint; signer: Address; agent: Address; validUntil: bigint }): Promise<Hex> {
    const w = this.wallet();
    return w.writeContract({
      address: this.address,
      abi: epkVaultAbi,
      functionName: "openSession",
      args: [args.envelopeId, args.signer, args.agent, Number(args.validUntil)],
      account: w.account,
      chain: w.chain,
    });
  }

  // ---------------------------------------------------------------- timelock

  /** Schedule a timelocked call (admin). `data` is the encoded call to one of the vault's own functions. */
  async schedule(data: Hex, salt: Hex): Promise<{ hash: Hex; operationId: Hex }> {
    const w = this.wallet();
    const hash = await w.writeContract({
      address: this.address,
      abi: epkVaultAbi,
      functionName: "schedule",
      args: [data, salt],
      account: w.account,
      chain: w.chain,
    });
    return { hash, operationId: hashOperation(data, salt) };
  }

  async executeScheduled(data: Hex, salt: Hex): Promise<Hex> {
    const w = this.wallet();
    return w.writeContract({
      address: this.address,
      abi: epkVaultAbi,
      functionName: "executeScheduled",
      args: [data, salt],
      account: w.account,
      chain: w.chain,
    });
  }

  /** Cancel a scheduled operation (admin, guardian or recovery; guardians are the veto). */
  async cancel(operationId: Hex): Promise<Hex> {
    const w = this.wallet();
    return w.writeContract({
      address: this.address,
      abi: epkVaultAbi,
      functionName: "cancel",
      args: [operationId],
      account: w.account,
      chain: w.chain,
    });
  }
}

/** Dig the revert data out of a viem error chain. */
export function findRevertData(e: unknown): Hex | undefined {
  let cur: unknown = e;
  for (let i = 0; i < 8 && cur; i++) {
    const c = cur as { data?: unknown; raw?: unknown; cause?: unknown };
    if (typeof c.raw === "string" && c.raw.startsWith("0x")) return c.raw as Hex;
    if (typeof c.data === "string" && c.data.startsWith("0x")) return c.data as Hex;
    if (c.data && typeof (c.data as { data?: unknown }).data === "string") return (c.data as { data: Hex }).data;
    cur = c.cause;
  }
  return undefined;
}
