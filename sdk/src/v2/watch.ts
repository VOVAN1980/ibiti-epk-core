import { type Address, type Hex, decodeFunctionData } from "viem";
import type { AnyPublicClient } from "./client.js";

import { epkVaultAbi } from "./abi/epkVaultAbi.js";

/** What a scheduled (timelocked) operation would do, decoded from its data — for alerts and dashboards. */
export function describeScheduledCall(data: Hex): { functionName: string; args: readonly unknown[] } | undefined {
  try {
    const d = decodeFunctionData({ abi: epkVaultAbi, data });
    return { functionName: d.functionName, args: (d.args ?? []) as readonly unknown[] };
  } catch {
    return undefined;
  }
}

/** Plain-language labels for the vault's timelocked functions (same wording as the Watchtower). */
export const scheduledCallLabels: Record<string, string> = {
  addDestination: "allow payments to a new address",
  setAsset: "track an asset / raise its limit",
  untrackAsset: "stop tracking an asset",
  createPolicy: "create a policy",
  updatePolicy: "change a policy (signer, expiry, value cap, guard)",
  setPolicyActive: "switch a policy on or off",
  setAgent: "allow or forbid an agent",
  setCall: "allow or forbid a call",
  setEnvelope: "open or widen an agent-session envelope",
  setEnvelopeCall: "allow or forbid an agent call",
  setEnvelopeBudgetCap: "change an agent budget",
  setEnvelopeGuard: "change the guard of agent sessions",
  setSessionManager: "set the session manager",
  setCoSigner: "set the co-signer",
  setGuardian: "add or remove a guardian",
  replaceGuardian: "replace a guardian",
  setDelay: "change the timelock delay",
  setAdmin: "change the admin",
  setRecovery: "change the recovery key",
  unpause: "unpause the vault",
  upgradeToAndCall: "UPGRADE the vault's code",
};

export type VaultEvent =
  | { kind: "scheduled"; id: Hex; readyAt: bigint; by: Address; call?: { functionName: string; args: readonly unknown[] }; label?: string }
  | { kind: "executed-operation"; id: Hex }
  | { kind: "cancelled"; id: Hex; by: Address }
  | { kind: "batch"; policyId: bigint; signer: Address; agent: Address }
  | { kind: "outflow"; token: Address; amount: bigint; availableAfter: bigint }
  | { kind: "paused"; by: Address }
  | { kind: "upgraded"; implementation: Address };

/**
 * Subscribe to what matters about one vault: scheduled changes (decoded and labelled), executions and
 * cancellations, batches, outflows, pauses and upgrades. Returns a function that stops watching.
 * `onError` receives every node / polling error — a monitor that silently stops is worse than none, so
 * alert on it (the default prints to stderr).
 */
export function watchVault(
  publicClient: AnyPublicClient,
  vault: Address,
  onEvent: (e: VaultEvent) => void,
  pollingInterval = 4_000,
  onError: (error: Error) => void = (error) => console.error(`watchVault ${vault}: ${error.message}`),
) {
  return publicClient.watchContractEvent({
    address: vault,
    abi: epkVaultAbi,
    pollingInterval,
    onError,
    onLogs: (logs) => {
      for (const log of logs as unknown as { eventName: string; args: Record<string, unknown> }[]) {
        const a = log.args;
        switch (log.eventName) {
          case "OperationScheduled": {
            const call = describeScheduledCall(a.data as Hex);
            onEvent({ kind: "scheduled", id: a.id as Hex, readyAt: BigInt(a.readyAt as bigint), by: a.by as Address, call, label: call ? scheduledCallLabels[call.functionName] : undefined });
            break;
          }
          case "OperationExecuted":
            onEvent({ kind: "executed-operation", id: a.id as Hex });
            break;
          case "OperationCancelled":
            onEvent({ kind: "cancelled", id: a.id as Hex, by: a.by as Address });
            break;
          case "Executed":
            onEvent({ kind: "batch", policyId: a.policyId as bigint, signer: a.signer as Address, agent: a.agent as Address });
            break;
          case "Outflow":
            onEvent({ kind: "outflow", token: a.token as Address, amount: a.amount as bigint, availableAfter: a.availableAfter as bigint });
            break;
          case "Paused":
            onEvent({ kind: "paused", by: a.by as Address });
            break;
          case "Upgraded":
            onEvent({ kind: "upgraded", implementation: a.implementation as Address });
            break;
        }
      }
    },
  });
}
