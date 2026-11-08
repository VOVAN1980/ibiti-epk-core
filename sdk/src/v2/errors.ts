import type { Hex } from "viem";

import { decodeEpkError } from "./vault.js";

/** What each EPK error means and what to do about it — for logs, dashboards and support. */
export const epkErrorHelp: Record<string, { meaning: string; fix: string }> = {
  // ---- batches: who may act, and when
  AgentNotAllowed: { meaning: "The sender is not an allowed agent of this policy or session.", fix: "Submit from the agent address the policy / session was opened for." },
  AgentExpired: { meaning: "The agent's permission on this policy has expired.", fix: "Renew it with setAgent (timelocked)." },
  BadSignature: { meaning: "The batch was not signed by the policy's / session's key (or for another agent, nonce, deadline, vault or chain).", fix: "Sign with signBatch for this vault, policy, agent and the current nonce." },
  PolicyInactive: { meaning: "The policy or session is switched off, or was cut off by panic / an envelope switch-off.", fix: "Open a new session, or have the owner re-activate the policy through the timelock." },
  PolicyNotFound: { meaning: "No policy or session with this id.", fix: "Check the id (sessions start at 2^128)." },
  Expired: { meaning: "The batch deadline or the policy expiry has passed.", fix: "Sign again with a later deadline." },
  DeadlineRequired: { meaning: "The batch has no deadline.", fix: "Pass a deadline (signBatch sets one hour by default)." },
  IsPaused: { meaning: "The vault is paused (a guardian or the admin pressed pause / panic).", fix: "Nothing can run until the owner unpauses through the timelock." },
  SetupNotFinished: { meaning: "The vault is still in setup; batches run only after finalizeSetup.", fix: "Admin: VaultAdmin.finalizeSetup()." },
  BadCalldata: { meaning: "Empty batch or more than 16 calls.", fix: "Send 1–16 calls per batch." },
  NonceTooLow: { meaning: "The nonce was already used or bumped.", fix: "Read the current nonce and sign again." },
  // ---- what a call may do
  CallNotAllowed: { meaning: "This target + function is not allowed for the policy / session envelope.", fix: "Owner: allow it with setCall / setEnvelopeCall (timelocked)." },
  DestinationNotAllowed: { meaning: "Funds or an approval would go to an address that is not on the vault's destination list.", fix: "Owner: addDestination (timelocked) — or this is an attack being stopped." },
  ValueTooHigh: { meaning: "Native value above the policy's / envelope's per-call cap.", fix: "Send less per call or raise the cap through the timelock." },
  UntrackedAsset: { meaning: "The token is not tracked (no limit configured), so the vault refuses to move it.", fix: "Owner: setAsset with a limit (timelocked)." },
  ForbiddenApproval: { meaning: "setApprovalForAll(true) is never allowed.", fix: "Approve single amounts inside a batch and reset them to 0." },
  AllowanceLeft: { meaning: "An approval made in the batch was not reset to 0 by its end.", fix: "End the batch with approve(spender, 0)." },
  TokenCallFailed: { meaning: "A token transfer / approve returned false.", fix: "Check balances and the token's rules." },
  BadTarget: { meaning: "The call targets the zero address or the vault itself.", fix: "Target the token, router or recipient instead." },
  GuardRequired: { meaning: "An agent session without a guard tried a call the vault cannot inspect itself (e.g. a swap).", fix: "Owner: give the envelope a guard (setEnvelopeGuard, timelocked) — or it is an agent going around the protection." },
  // ---- limits
  LimitExceeded: { meaning: "The vault-wide limit for this asset in the current window would be exceeded.", fix: "Wait for the window to refill (availableToSpend) or raise the limit through the timelock." },
  BudgetExceeded: { meaning: "This session's own budget for the asset would be exceeded.", fix: "Wait for it to refill (budgetAvailable) or use another session." },
  CoSignatureRequired: { meaning: "This outflow is above the co-sign threshold and needs the co-signer's signature.", fix: "Get getCoSignDigest signed by the co-signer and pass it as coSignature." },
  OutsideEnvelope: { meaning: "The session asked for more than its envelope allows (expiry or inactive envelope).", fix: "Open the session inside the envelope's max TTL, on an active envelope." },
  // ---- configuration and timelock
  NotTimelocked: { meaning: "This change loosens the rules and must go through the timelock.", fix: "Schedule it (VaultAdmin.apply after setup) and execute after the delay." },
  NotAdmin: { meaning: "Only the vault admin may do this.", fix: "Use the admin key." },
  NotAdminOrGuardian: { meaning: "Only the admin or a guardian may do this.", fix: "Use the admin or a guardian key." },
  NotAdminOrRecovery: { meaning: "Only the admin (or the recovery key for its own operations) may execute this.", fix: "Execute with the admin key." },
  NotRecovery: { meaning: "Only the recovery key may do this.", fix: "Use the recovery key." },
  NotSessionManager: { meaning: "Only the session manager may open / close sessions.", fix: "Use the session manager key." },
  OperationNotReady: { meaning: "The scheduled change's delay has not passed yet.", fix: "Wait until readyAt (see the OperationScheduled event)." },
  UnknownOperation: { meaning: "No such scheduled operation (never scheduled, executed, or cancelled by a guardian).", fix: "Schedule it again; if a guardian cancelled it, find out why." },
  StaleOperation: { meaning: "The scheduled change expired (grace period passed) or was invalidated by panic / an upgrade.", fix: "Schedule it again." },
  OperationExists: { meaning: "The same operation (data + salt) is already scheduled.", fix: "Use another salt or wait for it." },
  CannotCancel: { meaning: "This operation cannot be cancelled by this caller.", fix: "Use a key that may cancel it." },
  BadDelay: { meaning: "Delay out of range (1 hour – 30 days; from 5 minutes on test networks with vault 2.3).", fix: "Pick a delay in range." },
  BadRole: { meaning: "This address may not take that role (e.g. the vault itself, or an admin as guardian).", fix: "Use a separate key for each role." },
  TooFewGuardians: { meaning: "At least 2 guardians are needed before the vault can go live.", fix: "Add guardians, then finalizeSetup." },
  TooManyAssets: { meaning: "At most 16 tracked assets.", fix: "Untrack an asset first." },
  NotTighter: { meaning: "This instant change does not tighten the rules.", fix: "Loosening changes go through the timelock." },
  IsSession: { meaning: "Per-policy settings never apply to sessions.", fix: "Change the session's envelope instead." },
  SetupAlreadyFinished: { meaning: "The setup phase is over.", fix: "Use the timelock for further changes." },
  ZeroAddress: { meaning: "A required address is zero.", fix: "Pass a real address." },
  BadOperation: { meaning: "This operation is not allowed (e.g. a release without migration).", fix: "Use the dedicated function (e.g. scheduleUpgrade)." },
  ImplementationNotApproved: { meaning: "The new code is not (yet) an approved release of the vault's registry, or was revoked.", fix: "Wait for the release window to end; if revoked, do not upgrade." },
  NotNewerVersion: { meaning: "The release is not newer than the vault's current version.", fix: "Pick a newer release." },
  Reentrancy: { meaning: "A call tried to re-enter the vault.", fix: "Remove the re-entering call." },
  FailedCall: { meaning: "A call in the batch failed without a reason (e.g. the vault does not hold enough of the asset, or the target reverted silently).", fix: "Check the vault's balance and the target call." },
  // ---- DexGuard
  RecipientNotVault: { meaning: "The swap would send its output somewhere other than the vault.", fix: "Set the recipient / to to the vault — or this is an attack being stopped." },
  PriceTooLow: { meaning: "The swap accepts less than the Chainlink fair value minus the allowed slippage (bad pool or manipulated price).", fix: "Use DexGuardClient.minimumOut / planGuardedSwap; skip pools that are off the market." },
  PriceTooHigh: { meaning: "An exact-output swap would pay more than the fair value plus slippage.", fix: "Use DexGuardClient.maximumIn." },
  TokenNotAllowed: { meaning: "A token in the path is not on the guard's list.", fix: "Trade only listed tokens, or deploy a guard that lists it." },
  UnsupportedCall: { meaning: "A call the guard does not support: unknown router function, multicall, fee-on-transfer variants, other contracts.", fix: "Use a supported swap function on a configured router." },
  ApproveToNonRouter: { meaning: "An approval to an address that is not a configured router.", fix: "Approve only the router, and reset to 0 after the swap." },
  BadDeadline: { meaning: "The swap's own deadline is in the past or too far ahead.", fix: "Use a deadline within the guard's maxDeadline from now." },
  AmountTooLarge: { meaning: "The trade is larger than the guard's per-trade cap for this token.", fix: "Split it, or use a guard with a higher cap." },
  StalePrice: { meaning: "The Chainlink price is stale or inconsistent.", fix: "Wait for a fresh price; no reliable price, no swap." },
  BadPrice: { meaning: "The Chainlink price is zero, negative or outside the guard's sanity bounds.", fix: "Do not trade until the feed is healthy." },
  BalanceCheckFailed: { meaning: "After the batch, the vault received less than the swaps guaranteed (malicious router, transfer tax).", fix: "Avoid this router / token." },
  BadPath: { meaning: "The swap path is malformed, too long, or does not match native in/out.", fix: "Check the path." },
  BadAmount: { meaning: "Zero amount or zero minimum.", fix: "Set amounts and minimums." },
  NativeNotAllowed: { meaning: "Native value on a swap that cannot take it (token-in or V3 swaps).", fix: "Send value 0, or use a native-in V2 function." },
  BadConfig: { meaning: "The guard configuration is invalid.", fix: "See the DexGuard constructor rules." },
  PriceLimitNotAllowed: { meaning: "A V3 single-pool swap with a price limit: the router could fill only part of it while charging the full maximum.", fix: "Set sqrtPriceLimitX96 to 0." },
  RecipientNotAllowed: { meaning: "Tokens sent directly to a router or to the wrapped native token (anyone can sweep a router's balance; tokens sent to WBNB/WETH are lost).", fix: "Swap through the router with an approval; never transfer to it." },
  // ---- ThreatFeed V2 / CompositeGuard
  BlockedAddress: { meaning: "An address in the call is on the ThreatFeed blocklist (drainer, exploited token, compromised payee).", fix: "Do not interact with it; unblocking takes a delay and can be vetoed." },
  NotVault: { meaning: "Only the vault itself may call this composite on its own behalf.", fix: "Use the composite as the vault's guard, not directly." },
};

/** One line a human can act on, for any revert data from an EPK vault batch. */
export function explainEpkError(data: Hex): string {
  const e = decodeEpkError(data);
  if (!e) return `unknown revert (${data.slice(0, 10)})`;
  const name = e.errorName as string;
  if (name === "Error") return `revert: ${String((e.args as readonly unknown[] | undefined)?.[0] ?? "")}`;
  const help = epkErrorHelp[name];
  const args = e.args && (e.args as readonly unknown[]).length ? `(${(e.args as readonly unknown[]).join(", ")})` : "";
  const loosening = /timelock|addDestination|raise/i.test(help?.fix ?? "");
  const caution = loosening
    ? " (A called token or router can return the same error data: confirm on the vault before loosening anything.)"
    : "";
  return help ? `${name}${args}: ${help.meaning} → ${help.fix}${caution}` : `${name}${args}`;
}
