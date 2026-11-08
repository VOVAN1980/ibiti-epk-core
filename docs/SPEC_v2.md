# EPK v2 — EPKVault Specification

Status: **preview — live on BSC Testnet only, internally reviewed, not independently audited, not on any mainnet.**
Release 2.1 adds guards for agent sessions (`setEnvelopeGuard`, `GuardRequired`, `afterBatch`), parallel upgrade
clocks and 5-minute delays on public test networks — see [GUARDS_v2.md](GUARDS_v2.md) and
[EPK_V2_UPGRADE_ARCHITECTURE.md](EPK_V2_UPGRADE_ARCHITECTURE.md).
Contracts: `contracts/v2/EPKVault.sol`, `contracts/v2/EPKVaultFactory.sol`, `contracts/v2/EPKRegistry.sol`.
Tests: `test/v2/`. Review: [SECURITY_REVIEW_v2.md](SECURITY_REVIEW_v2.md).

## 1. The promise

> Even if the server, the operator key **and** the AI agent are compromised at the same time,
> the attacker cannot take more than the configured limit per time window, and cannot send funds
> to an address that was not allowlisted in advance — for the calls the vault inspects itself or a guard checks
> (§10).

The threat model covers a compromised **agent** and a compromised **operator signer** — the scenario of large exchange hacks where the signing infrastructure itself was made to sign attacker transactions.

## 2. Why one vault per customer

A **shared executor** — one contract that executes calls for many customers from its own address — is unsafe: any authority given to that address (token allowances, tokens it holds, roles granted to it) is usable by **every** customer, not only by the one who granted it.

EPK avoids this by construction: **every customer gets their own vault**. Funds sit in that vault, and calls are made from that vault. Nobody else's policy can reach them.

## 3. Roles

| Role | Who | Can | Cannot |
|---|---|---|---|
| **Operator signer** (per policy) | hot key, server, agent's own key, MPC or multisig (ERC-1271) | sign `Execute` batches inside the policy | change any rule |
| **Agent** (per policy) | bot / relayer / AI agent | submit batches signed for it (`execute`) | sign, change rules |
| **Co-signer** (per vault, optional) | independent service on separate infrastructure | approve a batch whose outflow is above `coSignAbove` | anything alone |
| **Admin** | multisig / cold key | tighten instantly; **schedule** loosening changes | loosen without the timelock; be a guardian |
| **Guardians** (≥ 2) | independent people / monitoring bots | pause, revoke, cancel pending changes, lower limits, `panic` | move funds, loosen anything, unpause, block their own removal |
| **Recovery** (optional, recommended) | cold key | replace a lost or compromised admin (2× delay); veto pending changes (except its own replacement, from 2.2.0) | move funds, execute admin operations |
| **Session manager** (optional) | separate hot key of the operator's backend | open agent sessions instantly inside approved envelopes; close sessions | widen any envelope, touch ordinary policies, open sessions while paused or before setup; be admin, guardian or recovery |

## 4. Lifecycle

1. **Create**: the future admin calls `EPKVaultFactory.createVault(guardians, delay, recovery, salt)`. The factory deploys an ERC-1967 proxy (permanent address) pointing at its fixed implementation and initializes it in the same transaction. The caller always becomes the admin (nobody can create a vault "for" someone else). CREATE2 with the salt bound to the caller. `delay` ∈ [1 hour, 30 days].
2. **Setup**: while `setupDone == false` the admin configures everything directly (assets, limits, destinations, policies, agents, calls, co-signer, guardians). **No funds can move during setup.**
3. **`finalizeSetup()`**: one-way switch; requires at least 2 guardians. From now on every loosening change goes through the timelock, and execution is enabled.

## 5. Execution

`execute(policyId, Call[] calls, deadline, signature, coSignature)` with `Call = (target, value, data)`, at most 16 calls, called by an allowed agent. Checks, in order:

1. setup finished, vault not paused, batch size 1..16;
2. policy exists, active, created in the current `epoch`; policy TTL; `deadline` set and in the future; agent allowed + agent TTL;
3. for **every** call:
   - `target` is not the vault itself; `(target, selector)` allowlisted (empty calldata = selector `0x00000000`, a plain native transfer; non-empty calldata may never use the zero selector);
   - `value ≤ maxValuePerCall`; native value only to allowlisted destinations;
   - ERC-20 `transfer` / `transferFrom` recipient must be allowlisted and the token tracked;
   - `approve` / `increaseAllowance`: the spender must be allowlisted (for every amount); a non-zero allowance is **recorded and must be back to zero when the batch ends**;
   - `setApprovalForAll(…, true)` is forbidden;
4. EIP-712 signature of the policy signer over policy, **agent**, calls, nonce and deadline (ECDSA, or ERC-1271 for contract signers);
5. optional policy validator for every call (`IPolicyValidator`, reverts bubble);
6. nonce increment, balance snapshot of all tracked assets, the calls (a `false` return from transfer/transferFrom/approve reverts);
7. **outflow settlement**: every real decrease of a tracked balance over the whole batch is charged to that asset's bucket; if the batch moves more than `coSignAbove`, the co-signer's signature over `CoSign(executeDigest)` is required;
8. every recorded allowance must be zero (pattern: `approve → use → approve(0)`).

## 6. Outflow limits (token bucket)

Per tracked asset (`NATIVE = address(0)` for the native coin): `maxPerWindow`, `window`, `coSignAbove`. Up to 16 tracked assets.

- The bucket refills linearly: `available = min(max, available + elapsed · max / window)`.
- Outflow is measured on **actual balance changes**, not on calldata, so "hidden" outflows (e.g. a router pulling via allowance inside the batch) are counted too.
- Guarantee: over any period `T`, outflow ≤ `max + max · T / window`. Example: `max = 2%` of holdings, `window = 1 day` → at most ~4% in the first day, ~2%/day after.
- An asset added after setup starts with an **empty** bucket.

## 7. Rule changes: tighten instantly, loosen slowly

| Instant (admin or any guardian) | Timelocked (`schedule` → `delay` → `executeScheduled`; admin directly only during setup) |
|---|---|
| `pause`, `revokeAll`, `panic` | `unpause` |
| `revokePolicy` (also kills queued signatures), `revokeAgent`, `disallowCall`, `bumpNonce` | `createPolicy`, `updatePolicy`, `setPolicyActive`, `setAgent`, `setCall` |
| `removeDestination` | `addDestination` |
| `lowerAssetLimit` (values may only go down) | `setAsset`, `untrackAsset` |
| `cancel(operationId)` | `setCoSigner`, `setGuardian`, `replaceGuardian`, `setDelay`, `setAdmin`, `setRecovery` |

- Every scheduled change emits `OperationScheduled(id, data, salt, readyAt, by)` — monitoring must watch it; any guardian can `cancel` within the delay.
- **Shielded operations**: removing or replacing a guardian cannot be cancelled by that guardian and is not invalidated by a panic, so one rogue guardian cannot freeze the vault forever. From 2.2.0, replacing the recovery key cannot be cancelled by the recovery key (so a stolen one cannot freeze the vault) and waits **3× delay** — longer than `recoverAdmin` — so an honest recovery key that reacts within one delay still beats a compromised admin; guardians, the admin and a panic can stop it. The guardian count can never drop below 2 after setup.
- **Recovery**: `recoverAdmin(newAdmin)` (recovery key only) schedules `setAdmin` with **2× delay**; the admin cannot cancel it and a panic does not invalidate it; any guardian can veto it.
- `executeScheduled` is called by the admin; the recovery key can execute only its own recovery operations. A ready operation must be executed within `GRACE_PERIOD` (14 days), otherwise it is stale and may be scheduled again.

## 8. Kill switch

- `pause()` — stops all execution. Unpausing is a loosening change (timelocked).
- `revokeAll()` — bumps `epoch`: **every** existing policy and every pending (non-shielded) operation becomes invalid at once. New policies must be created again (timelocked).
- `panic()` — both. One button, available to the admin and to every guardian.
- Allowances cannot outlive a batch, so there is no forgotten permission left behind after a panic.

## 9. Signatures

- Domain: `name = "EPK Vault"`, `version = "2"`, `chainId`, `verifyingContract = vault` — signatures cannot be replayed on another vault or chain (the domain is recomputed after a fork).
- Operator: `Execute(uint256 policyId,address agent,Call[] calls,uint256 nonce,uint256 deadline)Call(address target,uint256 value,bytes data)`; `calls` is hashed as the EIP-712 array of `Call` struct hashes.
- Co-signer: `CoSign(bytes32 executeDigest)` — a different digest, so one signature can never count as both.
- ECDSA (low-s enforced) first, then ERC-1271 for contract signers; the ERC-1271 answer must be exactly the 32-byte ABI-encoded magic value.
- Helpers: `getExecuteDigest(...)`, `getCoSignDigest(executeDigest)`.

## 10. Known limitations

See [SECURITY_REVIEW_v2.md §3](SECURITY_REVIEW_v2.md#3-residual-risks-and-design-limitations). The most important for integrators:

- For call types other than transfer / transferFrom / approve / increaseAllowance / setApprovalForAll, recipients inside the calldata are **not** checked — outflow limits still apply to tracked assets. Allowlist such calls (swaps, lending, bridges, Permit2) only together with a validator that checks their arguments.
- Track every asset the vault holds; untracked assets, positions in other tokens and NFTs are not limited.
- External validators must key their state by `msg.sender` (the vault) and should be immutable — a validator's own owner could otherwise change its rules outside the vault timelock.
- Guardians can cause denial of service (never theft); two colluding guardians can keep the vault frozen.

## 10b. Agent sessions (instant, bounded delegation for AI agents)

A **session** gives one agent its own key, its own budget and an expiry — opened **instantly**, without waiting for the timelock, but only inside an **envelope** the owner approved in advance.

**Envelope** (session template, id chosen by the admin):

| Setting | Function | Widening | Narrowing |
|---|---|---|---|
| on/off, max TTL, max native value per call | `setEnvelope(id, active, maxTtl, maxValuePerCall)` | timelock | instant (admin / guardian) |
| allowed calls `(target, selector)` | `setEnvelopeCall(id, target, selector, allowed)` | timelock | instant |
| budget per asset **for each session** (per window of that asset) | `setEnvelopeBudgetCap(id, asset, cap)` | timelock | instant |

Narrowing an envelope applies to **every open session of it at once**: sessions read the envelope's calls, budget caps and value cap live. `maxTtl` limits sessions opened from then on. Switching an envelope off ends all its sessions **for good** — a later (timelocked) re-activation does not revive them (envelope `generation`).

**Session manager**: an optional hot key (e.g. the operator's backend) set via `setSessionManager` — setting it is timelocked, removing it (`address(0)`) is instant. It must be a separate key: never the admin, a guardian or the recovery key.

**Opening**: `openSession(envelopeId, signer, agent, validUntil)` — **only the session manager** (so the admin key alone can never spend instantly); only after `finalizeSetup`; not while paused; `now < validUntil ≤ now + maxTtl`; `envelopeId < 2^64`. Creates a session with an id from `2^128` upward (never shifting ordinary policy ids), the envelope's value cap, and the agent allowed until the same expiry. `signer` can be the agent's own key (fully autonomous agent).

**Spending**: every outflow of a session is charged twice — against the **vault-wide** limit of the asset and against the **session's own budget** for that asset (a token bucket with capacity = the envelope's current cap; untouched = full). A session cannot move an asset its envelope gives no budget for. Destinations, allowance and co-signer rules apply as for any policy. Per-policy settings (`updatePolicy`, `setAgent`, `setCall`, `setPolicyActive`, `disallowCall`) never apply to sessions (`IsSession`).

**Closing**: expiry; `revokePolicy` (admin, guardian, or the session manager — sessions only); switching the envelope off; `panic` / `revokeAll`.

**If the session manager key leaks**: remove it (`setSessionManager(address(0))`, instant for any guardian) and `panic` or switch the envelope off. Until then it can open many sessions, each with a full budget — the vault-wide limit is the bound.

**Guarantee** (tested with a compromised session manager and compromised session keys, `test/v2/EPKVault.sessions.t.sol`): total outflow stays within the vault-wide limit, each session stays within its own budget, only allowlisted destinations receive funds, and nothing can be widened without the timelock.

## 11. Upgrades (opt-in, same address)

Each vault can move to a newer implementation without changing its address or moving funds — **only by its own decision**:

- `scheduleUpgrade(newImplementation, salt)` (admin) → **max(2× delay, 2 days)** → `executeScheduled` (admin);
- the new implementation must be approved in the vault's `EPKRegistry` (fixed per vault; 7-day public approval delay, revocable, codehash pinned, version read from the code) and have a strictly higher `vaultVersion()`;
- the release's own migration always runs once (vault-only; it receives the version the vault comes from, so skipped releases are handled); nothing else can ride along;
- ordinary operations still pending from the old release become stale;
- any guardian or the recovery key can cancel; `panic` / `revokeAll` invalidate a pending upgrade;
- no direct `upgradeToAndCall`, no generic `schedule` of it or of `migrate`, no downgrades;
- the registry and the factory have no power over existing vaults.

Full design, comparison with immutable / beacon / migration approaches, threats and release rules: [EPK_V2_UPGRADE_ARCHITECTURE.md](EPK_V2_UPGRADE_ARCHITECTURE.md).

## 12. Recommended configuration

- `delay` ≥ 24 hours; **at least 3 guardians** (the enforced minimum is 2) on infrastructure independent from the operator and from each other; a recovery key in cold storage. With only 2 guardians and no recovery key, a compromised admin plus one absent guardian can take over (see the upgrade architecture, §7).
- Monitoring bot as a guardian: auto-`cancel` unexpected `OperationScheduled`, auto-`panic` on anomalies.
- Co-signer: a co-signing service on separate infrastructure, with a low `coSignAbove`.
- `maxPerWindow` sized to what the business can afford to lose in one window.
