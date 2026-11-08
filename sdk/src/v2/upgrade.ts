import {
  type Account,
  type Address,
  type Chain,
  type Hex,
  type Transport,
  type WalletClient,
  encodeFunctionData,
  parseAbi,
} from "viem";
import type { AnyPublicClient } from "./client.js";

import { epkRegistryAbi } from "./abi/epkRegistryAbi.js";
import { epkVaultAbi } from "./abi/epkVaultAbi.js";
import { hashOperation } from "./vault.js";

const uupsAbi = parseAbi(["function upgradeToAndCall(address newImplementation, bytes data)", "function migrate()"]);

/** The exact operation an opt-in upgrade schedules (same bytes as `EPKVault.upgradeOperationData`). */
export function upgradeOperationData(newImplementation: Address): Hex {
  return encodeFunctionData({
    abi: uupsAbi,
    functionName: "upgradeToAndCall",
    args: [newImplementation, encodeFunctionData({ abi: uupsAbi, functionName: "migrate" })],
  });
}

export type Release = { version: number; activeAt: bigint; revoked: boolean; codehash: Hex };

/** Read-only view of an EPKRegistry (the public catalogue of releases vaults may opt into). */
export class EPKRegistryClient {
  constructor(
    readonly address: Address,
    readonly publicClient: AnyPublicClient,
  ) {}

  async release(implementation: Address): Promise<Release | undefined> {
    const [version, activeAt, revoked, codehash] = (await this.publicClient.readContract({
      address: this.address,
      abi: epkRegistryAbi,
      functionName: "releases",
      args: [implementation],
    })) as readonly [bigint, bigint, boolean, Hex];
    return version === 0n ? undefined : { version: Number(version), activeAt, revoked, codehash };
  }

  async isApproved(implementation: Address): Promise<boolean> {
    return this.publicClient.readContract({ address: this.address, abi: epkRegistryAbi, functionName: "isApproved", args: [implementation] });
  }

  /** Public release window: 7 days; 5 minutes on public test networks. */
  async approvalDelay(): Promise<bigint> {
    return this.publicClient.readContract({ address: this.address, abi: epkRegistryAbi, functionName: "approvalDelay" });
  }

  async latestVersion(): Promise<number> {
    return Number(await this.publicClient.readContract({ address: this.address, abi: epkRegistryAbi, functionName: "latestVersion" }));
  }
}

export type UpgradeStatus = {
  operationId: Hex;
  data: Hex;
  /**
   * What the owner can do now: "unlisted" | "revoked" (by the registry) | "not-scheduled" | "cancelled"
   * (vetoed by a guardian / the recovery key / the admin, or wiped by a panic — schedule again) |
   * "waiting" | "ready" | "done" (the vault already runs this version or a newer one)
   */
  state: "unlisted" | "revoked" | "not-scheduled" | "cancelled" | "waiting" | "ready" | "done";
  release?: Release;
  /** when the vault's own wait ends (from the OperationScheduled event), if scheduled */
  readyAt?: bigint;
  /** earliest moment the upgrade can run: max(vault wait, registry approval) */
  executableAt?: bigint;
  currentVersion: number;
};

/**
 * Opt-in upgrades of one vault: plan, schedule, check, execute. Both clocks — the registry's public release
 * window and the vault's own wait — run in parallel (vault 2.1.0+); the code runs only once approved.
 */
export class EPKUpgrader {
  constructor(
    readonly vault: Address,
    readonly publicClient: AnyPublicClient,
    readonly walletClient?: WalletClient<Transport, Chain, Account>,
  ) {}

  private wallet() {
    if (!this.walletClient) throw new Error("EPKUpgrader: a walletClient (the vault admin) is needed to send transactions");
    return this.walletClient;
  }

  async registry(): Promise<EPKRegistryClient> {
    const r = await this.publicClient.readContract({ address: this.vault, abi: epkVaultAbi, functionName: "registry" });
    return new EPKRegistryClient(r as Address, this.publicClient);
  }

  async currentVersion(): Promise<number> {
    return Number(await this.publicClient.readContract({ address: this.vault, abi: epkVaultAbi, functionName: "vaultVersion" }));
  }

  /** Schedule the opt-in upgrade (vault admin). Guardians and the Watchtower see it and can veto. */
  async schedule(newImplementation: Address, salt: Hex): Promise<{ hash: Hex; operationId: Hex }> {
    const w = this.wallet();
    const hash = await w.writeContract({
      address: this.vault,
      abi: epkVaultAbi,
      functionName: "scheduleUpgrade",
      args: [newImplementation, salt],
      account: w.account,
      chain: w.chain,
    });
    return { hash, operationId: hashOperation(upgradeOperationData(newImplementation), salt) };
  }

  /** Execute a scheduled upgrade once `status` says "ready" (vault admin). */
  async execute(newImplementation: Address, salt: Hex): Promise<Hex> {
    const w = this.wallet();
    return w.writeContract({
      address: this.vault,
      abi: epkVaultAbi,
      functionName: "executeScheduled",
      args: [upgradeOperationData(newImplementation), salt],
      account: w.account,
      chain: w.chain,
    });
  }

  /**
   * Where an upgrade stands. `fromBlock` bounds the event search for the schedule (public nodes limit
   * log ranges; pass a block shortly before scheduling).
   */
  async status(newImplementation: Address, salt: Hex, fromBlock: bigint): Promise<UpgradeStatus> {
    const data = upgradeOperationData(newImplementation);
    const operationId = hashOperation(data, salt);
    const [reg, currentVersion] = await Promise.all([this.registry(), this.currentVersion()]);
    const release = await reg.release(newImplementation);
    const base = { operationId, data, release, currentVersion };
    if (!release) return { ...base, state: "unlisted" };
    if (release.version <= currentVersion) return { ...base, state: "done" };
    if (release.revoked) return { ...base, state: "revoked" };

    const event = epkVaultAbi.find((x) => x.type === "event" && x.name === "OperationScheduled");
    const logs = await this.publicClient.getLogs({
      address: this.vault,
      event: event as never,
      args: { id: operationId } as never,
      fromBlock,
      toBlock: "latest",
    });
    if (logs.length === 0) return { ...base, state: "not-scheduled" };
    const last = logs[logs.length - 1] as unknown as { blockNumber: bigint; logIndex: number; args: { readyAt: bigint } };
    const readyAt = BigInt(last.args.readyAt);
    // vetoed (OperationCancelled for this id) or wiped by a panic (EpochBumped) after the latest schedule?
    const after = (l: { blockNumber: bigint | null; logIndex: number | null }) =>
      l.blockNumber !== null && (l.blockNumber > last.blockNumber || (l.blockNumber === last.blockNumber && (l.logIndex ?? 0) > last.logIndex));
    const cancelledEv = epkVaultAbi.find((x) => x.type === "event" && x.name === "OperationCancelled");
    const epochEv = epkVaultAbi.find((x) => x.type === "event" && x.name === "EpochBumped");
    const [cancels, epochs] = await Promise.all([
      this.publicClient.getLogs({ address: this.vault, event: cancelledEv as never, args: { id: operationId } as never, fromBlock: last.blockNumber, toBlock: "latest" }),
      this.publicClient.getLogs({ address: this.vault, event: epochEv as never, fromBlock: last.blockNumber, toBlock: "latest" }),
    ]);
    if ([...cancels, ...epochs].some((l) => after(l as never))) return { ...base, readyAt, state: "cancelled" };
    const executableAt = readyAt > release.activeAt ? readyAt : release.activeAt;
    const now = (await this.publicClient.getBlock()).timestamp;
    return { ...base, readyAt, executableAt, state: now >= executableAt ? "ready" : "waiting" };
  }
}
