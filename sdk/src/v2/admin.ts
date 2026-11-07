import {
  type Account,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type Transport,
  type WalletClient,
  decodeEventLog,
  encodeFunctionData,
  keccak256,
  maxUint128,
  toBytes,
  toFunctionSelector,
} from "viem";

import { epkVaultAbi } from "./abi/epkVaultAbi.js";
import { epkVaultFactoryAbi } from "./abi/epkVaultFactoryAbi.js";
import { hashOperation, NATIVE } from "./vault.js";

/** One configuration change of a vault, ready to send directly (setup) or through the timelock (later). */
export type VaultAction = { functionName: string; args: readonly unknown[]; data: Hex; label: string };

const act = (functionName: string, args: readonly unknown[], label: string): VaultAction => ({
  functionName,
  args,
  data: encodeFunctionData({ abi: epkVaultAbi, functionName: functionName as never, args: args as never }),
  label,
});

/** 4-byte selector of a function signature, e.g. selector("transfer(address,uint256)"). */
export const selector = (signature: string): Hex => toFunctionSelector(signature);

/** Selector the vault uses for a plain native-coin transfer (empty calldata). */
export const NATIVE_TRANSFER: Hex = "0x00000000";

/**
 * Builders for the vault's configuration functions. During setup the admin sends them directly; after
 * `finalizeSetup` every loosening change goes through the timelock (`VaultAdmin.apply` does both).
 */
export const vaultActions = {
  /** Track an asset with a limit per window (NATIVE = native coin). `coSignAbove`: above this one batch needs the co-signer. */
  setAsset: (token: Address, maxPerWindow: bigint, windowSeconds: number, coSignAbove: bigint = maxUint128) =>
    act("setAsset", [token, maxPerWindow, windowSeconds, coSignAbove], `track ${token === NATIVE ? "native coin" : token}: ${maxPerWindow} per ${windowSeconds}s`),
  /** Allow payments / approvals / native value to this address (e.g. your treasury, a router). */
  addDestination: (destination: Address) => act("addDestination", [destination], `allow payments to ${destination}`),
  /** A policy for a bot / operator key. `guard`: an EPK guard (DexGuard, CompositeGuard…) or zero. Returns its id via VaultAdmin. */
  createPolicy: (signer: Address, validUntil: number, maxValuePerCall: bigint, guard: Address = NATIVE) =>
    act("createPolicy", [signer, validUntil, maxValuePerCall, guard], `create a policy for signer ${signer}`),
  setAgent: (policyId: bigint, agent: Address, allowed = true, validUntil = 0) =>
    act("setAgent", [policyId, agent, allowed, validUntil], `${allowed ? "allow" : "forbid"} agent ${agent} on policy ${policyId}`),
  /** Allow `target.selector` for a policy (use NATIVE_TRANSFER for plain native transfers). */
  setCall: (policyId: bigint, target: Address, fnSelector: Hex, allowed = true) =>
    act("setCall", [policyId, target, fnSelector, allowed], `${allowed ? "allow" : "forbid"} ${fnSelector} on ${target} for policy ${policyId}`),
  setSessionManager: (manager: Address) => act("setSessionManager", [manager], `set the session manager ${manager}`),
  /** Envelope for AI-agent sessions: longest session and native value cap per call. */
  setEnvelope: (envelopeId: bigint, active: boolean, maxTtlSeconds: number, maxValuePerCall: bigint) =>
    act("setEnvelope", [envelopeId, active, maxTtlSeconds, maxValuePerCall], `${active ? "open" : "close"} session envelope ${envelopeId}`),
  setEnvelopeCall: (envelopeId: bigint, target: Address, fnSelector: Hex, allowed = true) =>
    act("setEnvelopeCall", [envelopeId, target, fnSelector, allowed], `${allowed ? "allow" : "forbid"} ${fnSelector} on ${target} in envelope ${envelopeId}`),
  /** Per-window budget of `asset` that EACH session of the envelope gets. */
  setEnvelopeBudgetCap: (envelopeId: bigint, asset: Address, cap: bigint) =>
    act("setEnvelopeBudgetCap", [envelopeId, asset, cap], `session budget ${cap} of ${asset} in envelope ${envelopeId}`),
  /** Guard for every session of the envelope (vault 2.1+). Without one, sessions cannot make calls the vault cannot inspect. */
  setEnvelopeGuard: (envelopeId: bigint, guard: Address) => act("setEnvelopeGuard", [envelopeId, guard], `guard ${guard} for envelope ${envelopeId}`),
  updatePolicy: (policyId: bigint, signer: Address, validUntil: number, maxValuePerCall: bigint, guard: Address) =>
    act("updatePolicy", [policyId, signer, validUntil, maxValuePerCall, guard], `update policy ${policyId}`),
  setGuardian: (guardian: Address, enabled: boolean) => act("setGuardian", [guardian, enabled], `${enabled ? "add" : "remove"} guardian ${guardian}`),
  setCoSigner: (coSigner: Address) => act("setCoSigner", [coSigner], `set the co-signer ${coSigner}`),
  setDelay: (seconds: bigint) => act("setDelay", [seconds], `set the timelock delay to ${seconds}s`),
};

export type ApplyResult = {
  /** sent directly (setup phase) */
  sent: { action: VaultAction; hash: Hex }[];
  /** scheduled in the timelock (after setup): execute them with `executeScheduled` once ready */
  scheduled: { action: VaultAction; hash: Hex; operationId: Hex; salt: Hex }[];
  /** ids of policies created by these actions, in order */
  policyIds: bigint[];
};

/** The vault admin's tools: configure during setup, finalize, and use the timelock afterwards. */
export class VaultAdmin {
  constructor(
    readonly vault: Address,
    readonly publicClient: PublicClient,
    readonly walletClient: WalletClient<Transport, Chain, Account>,
  ) {}

  async setupDone(): Promise<boolean> {
    return this.publicClient.readContract({ address: this.vault, abi: epkVaultAbi, functionName: "setupDone" }) as Promise<boolean>;
  }

  private async send(functionName: string, args: readonly unknown[]): Promise<Hex> {
    const w = this.walletClient;
    const hash = await w.writeContract({
      address: this.vault,
      abi: epkVaultAbi,
      functionName: functionName as never,
      args: args as never,
      account: w.account,
      chain: w.chain,
    });
    const rc = await this.publicClient.waitForTransactionReceipt({ hash });
    if (rc.status !== "success") throw new Error(`${functionName} reverted (tx ${hash})`);
    return hash;
  }

  /**
   * Apply configuration changes. Before `finalizeSetup` they take effect at once; afterwards each one is
   * scheduled in the timelock (guardians and the Watchtower can veto) — pass a `saltPrefix` you can find
   * again, and call `executeScheduled` when the delay has passed.
   */
  async apply(actions: VaultAction[], saltPrefix = "epk-sdk"): Promise<ApplyResult> {
    const out: ApplyResult = { sent: [], scheduled: [], policyIds: [] };
    const direct = !(await this.setupDone());
    for (const [i, action] of actions.entries()) {
      if (direct) {
        const hash = await this.send(action.functionName, action.args);
        out.sent.push({ action, hash });
        if (action.functionName === "createPolicy") out.policyIds.push(await this.policyIdFrom(hash));
      } else {
        const salt = keccak256(toBytes(`${saltPrefix}:${i}:${action.data}`));
        const hash = await this.send("schedule", [action.data, salt]);
        out.scheduled.push({ action, hash, operationId: hashOperation(action.data, salt), salt });
      }
    }
    return out;
  }

  /** Run timelocked changes whose delay has passed (admin). */
  async executeScheduled(items: { action: VaultAction; salt: Hex }[]): Promise<Hex[]> {
    const hashes: Hex[] = [];
    for (const it of items) hashes.push(await this.send("executeScheduled", [it.action.data, it.salt]));
    return hashes;
  }

  /** End the setup phase: from now on loosening changes need the timelock. Needs at least 2 guardians. */
  async finalizeSetup(): Promise<Hex> {
    return this.send("finalizeSetup", []);
  }

  private async policyIdFrom(hash: Hex): Promise<bigint> {
    const rc = await this.publicClient.getTransactionReceipt({ hash });
    for (const log of rc.logs) {
      try {
        const ev = decodeEventLog({ abi: epkVaultAbi, data: log.data, topics: log.topics });
        if (ev.eventName === "PolicyCreated") return (ev.args as unknown as { policyId: bigint }).policyId;
      } catch {
        /* not a vault event */
      }
    }
    throw new Error(`no PolicyCreated event in ${hash}`);
  }
}

/** Create a vault for yourself: the caller becomes its admin (nobody can create a vault "for" you). */
export class EPKFactoryClient {
  constructor(
    readonly address: Address,
    readonly publicClient: PublicClient,
    readonly walletClient?: WalletClient<Transport, Chain, Account>,
  ) {}

  /** Address the vault will have — known before it exists (CREATE2, bound to the admin). */
  async predictVault(args: { admin: Address; guardians: readonly Address[]; delay: bigint; recovery: Address; salt: Hex }): Promise<Address> {
    return this.publicClient.readContract({
      address: this.address,
      abi: epkVaultFactoryAbi,
      functionName: "predictVaultAddress",
      args: [args.admin, [...args.guardians], args.delay, args.recovery, args.salt],
    }) as Promise<Address>;
  }

  /**
   * Create a vault. `guardians`: at least 2 independent keys or services (they can only stop, never move
   * funds); `delay`: timelock for loosening changes (>= 1 hour); `recovery`: a cold key that can replace
   * the admin through the timelock.
   */
  async createVault(args: { guardians: readonly Address[]; delay: bigint; recovery: Address; salt: Hex }): Promise<{ vault: Address; hash: Hex }> {
    const w = this.walletClient;
    if (!w) throw new Error("EPKFactoryClient: a walletClient is needed to create a vault");
    const hash = await w.writeContract({
      address: this.address,
      abi: epkVaultFactoryAbi,
      functionName: "createVault",
      args: [[...args.guardians], args.delay, args.recovery, args.salt],
      account: w.account,
      chain: w.chain,
    });
    const rc = await this.publicClient.waitForTransactionReceipt({ hash });
    for (const log of rc.logs) {
      try {
        const ev = decodeEventLog({ abi: epkVaultFactoryAbi, data: log.data, topics: log.topics });
        if (ev.eventName === "VaultCreated") return { vault: (ev.args as unknown as { vault: Address }).vault, hash };
      } catch {
        /* other logs */
      }
    }
    throw new Error(`createVault: no VaultCreated event (tx ${hash})`);
  }
}
