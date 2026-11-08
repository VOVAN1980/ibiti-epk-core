# EPK v2 — next stage: guards, SDK v2, Watchtower (design draft)

Status: design written 2026-11-07; steps 1, 3 and 4 are built (preview). Order and status live in [ROADMAP.md](ROADMAP.md); this page explains
*how* the next milestones will work.

**Update 2026-11-08:** steps 1 and 3 below — DexGuard, ThreatFeed V2, CompositeGuard and vault release
2.1.0 with guards for agent sessions — are built and tested (preview, BSC Testnet), and step 4, the SDK, is on
npm as `@ibiti/epk-sdk`. What they
block, what they do not cover and how to connect them: [GUARDS_v2.md](GUARDS_v2.md). Goal of the stage: EPK that outside developers can integrate
and that trading-bot and AI-agent companies will pay to run with real money.

## 1. Why guards come first

The biggest open gap is in the [security review §3.1](SECURITY_REVIEW_v2.md#3-residual-risks-and-design-limitations):
calls other than plain transfers and approvals are not inspected. A trading bot needs swaps; without a
guard a compromised operator could route a swap's output to its own address or accept a terrible price —
bounded by the outflow limit, but still a loss. Guards close that gap for the customers most likely
to pay: bots and agents that trade.

## 2. How a guard plugs in (no vault change for ordinary policies)

- The vault calls `IPolicyValidator.validate(policyId, signer, agent, target, value, data)` for every
  call of a batch, after the signature check and before anything runs. A revert rejects the whole
  batch. `msg.sender` is the vault, so a guard keys everything by the vault.
- A policy gets its guard through `createPolicy` / `updatePolicy` — timelocked, guardians can veto.
  Removing or replacing a guard is a loosening and waits in the timelock too.
- **Guards are immutable.** Nobody can change a guard's rules outside the vault's timelock: new rules
  mean a new guard instance plus a timelocked `updatePolicy`. (Exception: the threat feed may only
  *add* blocks — it can stop calls, never move funds, the same trust level as a guardian.)
- **CompositeGuard** runs several guards in one slot (all must pass).

**Agent sessions needed a vault release.** On 2.0.x vaults sessions run with no validator. Vault release **2.1.0** adds a guard to each session envelope (set through the
timelock; applies to every session of the envelope). `EPKVault` 2.1.0 was 24,562 of 24,576 bytes, so the
change was kept small (2.2.0: 24,102 bytes, compiled for the Shanghai EVM). Each vault opts in through the registry and its own timelock.

## 3. DEX Guard

Routers first supported on BSC: PancakeSwap / Uniswap **V2-style** routers and **V3-style**
`exactInputSingle` / `exactInput` / `exactOutputSingle` / `exactOutput`. Universal-router command
streams come later.

Every call to a configured router must pass all of these, or the batch is rejected:

| Check | Why |
|---|---|
| Function is in the guard's supported list | an allowlisted router cannot be used through some other function |
| Recipient = the vault | swap output cannot be sent to the attacker |
| Every token in the path is on the guard's token list | no swaps into worthless or malicious tokens |
| Deadline ≤ now + `maxDeadline` | a signed swap cannot be held back and replayed at a worse time |
| Minimum out ≥ fair value × (1 − `maxSlippageBps`); for exact-output swaps, maximum in ≤ fair value × (1 + `maxSlippageBps`) | no "sell everything for nothing" — fair value from Chainlink price feeds, with a staleness limit and positive-answer check |
| Native-in swaps use the call's `value` as the amount in; native-out swaps price the wrapped native token | the same rule for BNB as for tokens |

Not covered (documented, not hidden): MEV inside the allowed slippage, fee-on-transfer and rebasing
tokens (rejected), and the pools themselves. A missing or stale price feed rejects the swap — safe
by default.

## 4. ThreatFeed V2

- A shared on-chain blocklist of addresses kept by a feed operator.
  Vaults opt in by adding the feed guard to a policy.
- Checks the call target and the address arguments of transfers and approvals (recipient, spender,
  operator).
- Blocking is instant; **unblocking waits a delay**, so a captured feed key cannot quietly open a
  blocked address.
- Checks a real list (not a single hash compared with a root).

## 5. SDK v2 (TypeScript, viem)

| Module | What it gives an integrator |
|---|---|
| `read` | limits left, session budgets, destinations, roles, pending operations, version |
| `sign` | EIP-712 batch signatures identical to the vault's digest; co-signatures |
| `sessions` | open / close agent sessions inside an envelope |
| `timelock` | schedule / execute / cancel with the same operation id as the contract |
| `upgrade` | check a release in the registry, schedule and execute an opt-in upgrade |
| `guards` | build and deploy DEX Guard / ThreatFeed / Composite configurations |
| `watch` | typed events for dashboards and alerts |

Tested offline against reference values taken from the live testnet vault (digests, operation ids, every
on-chain rejection). Examples: quickstart (your own vault from zero), guarded swap, opt-in upgrade.

## 6. Watchtower — from demo to service

- Always on: Docker image and a service unit, health endpoint, restart-safe state.
- More alert channels: Telegram (already supported), e-mail and webhooks.
- The owner signs the list of planned operations, instead of editing a file on the server.

## 7. Order

1. DEX Guard, CompositeGuard and ThreatFeed V2 for ordinary policies — contracts, unit, fuzz and fork tests.
2. ~~2026-11-14 / 16: the 2.0.1 upgrade demo~~ — cancelled; the opt-in upgrade was shown on 2.1 in 5 minutes.
3. Vault release 2.1.0: guards for agent sessions.
4. SDK v2 covering the vault, sessions and guards.
5. Watchtower as a service.
6. Freeze the audit scope; independent audit; mainnet only after it.
