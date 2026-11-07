# EPK v2 (EPKVault) — Internal Security Review

| | |
|---|---|
| Scope | `contracts/v2/EPKVault.sol`, `contracts/v2/EPKVaultFactory.sol`, `contracts/v2/EPKRegistry.sol` (upgrade mechanism: second and third rounds, §1b–§1c) |
| Date | 2026-11-06 |
| Method | Internal review by a separate AI agent (code reading + Foundry proof-of-concept tests), fixes by the developer, regression tests for every finding |
| Status | All high / medium findings fixed. **Not an independent audit.** |

> ⚠️ This document records an internal review. It is **not** a substitute for an independent audit by a
> professional security firm. EPK v2 must not hold significant real funds before such an audit,
> a public testnet period and a bug bounty.

## 1. Findings

| ID | Severity | Finding | Status | Regression test |
|---|---|---|---|---|
| H-1 | High | `approve` cost nothing against the limit, had no upper bound and survived `panic`; the spender could pull everything later, outside `execute` | **Fixed** — batches (`Call[]`); every allowance created in a batch must be **zero when the batch ends** (approve → use → approve 0); `increaseAllowance` treated like `approve`; `setApprovalForAll(…, true)` forbidden | `test_allowanceCannotOutliveTheBatch`, `test_batchApproveUseResetWorksAndIsCounted`, `test_setApprovalForAllForbidden`, `invariant_noAllowanceSurvives` |
| M-1 | Medium | A single guardian could freeze the vault forever (panic + cancel every unpause and its own removal) | **Fixed** — at least 2 guardians required to go live, admin can never be a guardian; removing/replacing a guardian is *shielded*: that guardian cannot cancel it and a panic does not invalidate it | `test_rogueGuardianCannotFreezeForever`, `test_guardianCountCannotDropBelowMinimum`, `test_finalizeNeedsTwoGuardians_adminIsNeverGuardian` |
| M-2 | Medium | No recovery from a lost or compromised admin key | **Fixed** — optional `recovery` key: `recoverAdmin` schedules an admin change with 2× delay that survives panic and that the admin cannot cancel; any guardian can veto it (stolen recovery key) | `test_recoveryReplacesLostOrStolenAdmin`, `test_guardianCanVetoStolenRecoveryKey` |
| L-1 | Low | ERC-1271 check compared only the first 4 bytes of the answer (an echoing contract accepted any signature) | **Fixed** — answer must be exactly the 32-byte ABI-encoded magic value | `test_echoContractIsNotAValidSigner` |
| L-2 | Low | The plain-native-transfer permission (selector `0x00000000`) also allowed calldata starting with four zero bytes | **Fixed** — non-empty calldata may never use the zero selector | `test_zeroSelectorWithDataRejected` |
| L-3 | Low | A tracked token whose `balanceOf` reverts blocks every `execute` | **Documented** — keep the tracked set small; remove a broken asset with `untrackAsset` (timelocked) | — |
| L-4 | Low | ERC-721 `approve(x, 0)` (token #0) skipped the destination check | **Fixed** — the spender is checked for every amount | `test_approveToUnknownSpenderBlocked_evenAmountZero` |
| L-5 | Low | Anyone could create a vault naming any admin (with guardians they chose) | **Fixed** — the factory caller always becomes the admin | `test_factoryCallerIsAdmin_predictsAddress` |
| I-1 | Info | Co-signature used the same digest as the operator signature | **Fixed** — separate `CoSign(bytes32 executeDigest)` typed data | `test_coSignatureUsesSeparateDigest` |
| I-2 | Info | A stale operation blocked re-scheduling the same data+salt after a panic | **Fixed** — stale operations can be overwritten | `test_panicKillsPoliciesAndPendingChanges_rescheduleWorks` |
| I-3 | Info | `bumpNonce(type(uint256).max)` bricked the policy | **Fixed** — rejected | — |
| I-4 | Info | `untrackAsset` + `setAsset` refilled the limit to full | **Fixed** — assets added after setup start with an empty bucket | `test_assetAddedAfterSetupStartsEmpty` |
| I-5 | Info | Tokens returning `false` consumed a nonce without moving funds | **Fixed** — a `false` return of transfer/transferFrom/approve reverts | `test_tokenReturningFalseReverts` |
| I-6 | Info | Signature did not bind the agent; re-activating a revoked policy revived queued signatures | **Fixed** — `agent` is part of the signed data; `revokePolicy` bumps the nonce | `test_signatureBoundToAgent`, `test_revokePolicyKillsQueuedSignatures` |
| I-7 | Info | No ERC-721/1155 receiver hooks; `transferFrom` into the vault is refused | **Documented** | — |
| I-8 | Info | Validators get no vault argument; an external validator's owner can change its rules outside the vault timelock | **Documented** — validators must key state by `msg.sender` (the vault); prefer immutable validators | — |

### 1b. Upgrade mechanism — second review round

Scope: proxy/UUPS refactor of `EPKVault`, `EPKRegistry`, `EPKVaultFactory`. No critical or high findings.

| ID | Severity | Finding | Status | Regression test |
|---|---|---|---|---|
| F1 | Medium | Admin could swap the registry (`setRegistry`, 1× delay) for an attacker registry and then install any code | **Fixed** — `setRegistry` removed; the registry is fixed per vault | (function no longer exists) |
| F2 | Medium | Migration functions written with only `reinitializer(n)` were callable by anyone | **Fixed** — upgrades can attach only the release's own `migrate()`, which must also require `msg.sender == address(this)`; `migrate` cannot be scheduled generically | `test_migrationOnlyByTheVaultItself` |
| F3 | Low | Registry version not tied to the code's `vaultVersion()` (allowed downgrades) | **Fixed** — the registry reads the version from the implementation | `test_registryRules` |
| F4 | Low | Factory kept deploying a revoked implementation | **Fixed** — factory requires `registry.isApproved(implementation)` | `test_factoryRefusesRevokedImplementation` |
| F5 | Low | "2× delay" could be shortened by lowering the delay first | **Fixed** — `UPGRADE_DELAY_FLOOR = 2 days` | `test_upgradeDelayFloorAfterLoweringDelay`, `invariant_upgradeNeverFasterThanTheFloor` |
| F6 | Low | Upgrade `data` was a general "call as the vault" channel (nested upgrades, recovery change) | **Fixed** — `scheduleUpgrade(impl, bool withMigration, salt)`: payload is empty or `migrate()` only | `test_upgradeOperationDataMatchesHelper` |
| F7 | Low | Proxy could not receive native coins via 2300-gas `transfer`/`send` in a cold transaction | **Fixed** — `EPKVaultProxy.receive()` | `test_vaultAcceptsStipendTransfers` |
| F8 | Low | A compromised registry owner could exhaust the version space | **Fixed** — `MAX_VERSION_STEP = 10_000` per release | `test_registryRules` |
| I1 | Info | Storage snapshot missing; contract size margin small | **Fixed / documented** — `docs/storage-layout/EPKVault-2.0.0.txt`, `extra_output = ["storageLayout"]`; size budget in release rules | — |
| I2 | Info | Codehash pin does not cover EIP-7702 delegated code | **Fixed** — registry rejects code starting with `0xEF` | `test_registryRejectsDelegatedCode` |
| I3 | Info | Compromised admin + approved-but-buggy release = compromise; no rollback | **Documented** (audit, 7-day window, revocation, guardian veto) | — |
| I4 | Info | Pending operations survive upgrades | **Documented** — releases that change scheduling rules bump `epoch` in `migrate()` | — |
| I5 | Info | `initialize` did not reject the vault itself as guardian/recovery | **Fixed** | — |
| I6 | Info | `factory.isVault` is not a trust signal | **Documented** in code and docs | — |
| I7 | Info | Recovery key could execute any ready admin operation | **Fixed** — recovery executes only its own recovery operations | `test_recoveryCannotExecuteAdminOperations` |
| I8 | Info | EIP-712 version fixed; no ERC-5267 | **Documented** (release rule; future work) | — |
| I9 | Info | Upgrade invariant handler lacked delay/migration actions | **Fixed** — handler now lowers the delay, uses migrations and generic scheduling | invariants |

### 1c. Upgrade mechanism — third review round (re-review of the fixed path)

No critical or high findings; the only way for a vault to change its code is an operation created by `scheduleUpgrade`.

| ID | Severity | Finding | Status | Regression test |
|---|---|---|---|---|
| M-1 | Medium | The documented cumulative-migration pattern read `_getInitializedVersion()` inside a `reinitializer`, where it already equals `n` → steps silently skipped for vaults that skip a release | **Fixed** — base `migrate()` (not overridable) captures the `from` version before calling the release's `_migrate(from)` | `test_skippedReleaseMigrationStillRuns`, `test_stepByStepMigrationRunsEachStepOnce` |
| M-2 | Medium | Docs overstated the takeover threshold: with 2 guardians, a compromised admin plus one absent guardian can replace the honest guardian (shielded op) | **Fixed / documented** — the recovery key can now veto any pending operation; trust model states the real threshold; recommend ≥ 3 guardians + recovery key | `test_recoveryVetoesGuardianReplacementWhenAGuardianIsAbsent` |
| L-1 | Low | Pending operations were not tied to the release they were scheduled under; migrations were optional | **Fixed** — operations record `vaultVersion()`; ordinary ones go stale on upgrade; the migration always runs | `test_pendingOperationsGoStaleAfterUpgrade`, `test_releaseWithoutMigrationCannotBeInstalled` |
| L-2 | Low | A compromised admin could squat the recovery operation's id or poison its target | **Fixed / documented** — recovery operations replace look-alike ordinary operations and cannot be squatted back; poisoning changes are timelocked and vetoable by guardians or the recovery key | `test_recoveryReplacesSquattedOperation` |
| L-3 | Low | The migration caller check depended on release authors | **Fixed** — enforced by the base `migrate()` | `test_migrationOnlyByTheVaultItself` |
| I-a | Info | The vault could be configured as its own signer / validator / co-signer | **Fixed** — rejected | `test_vaultCannotBeItsOwnSignerValidatorOrCoSigner` |
| I-b | Info | Registry: no owner succession, permanent revocation, chained version steps, codehash pin does not cover delegatecall, `0xEF` check vs EOF | **Documented** (§7, §11 of the upgrade architecture) | — |
| I-c | Info | `pause` alone does not stop upgrades | **Documented** — `panic`/`revokeAll` do; monitoring must re-veto | — |
| I-d | Info | `migrate()` runs with the reentrancy lock held | **Documented** in release rules | — |
| I-e | Info | `initialize` did not reject the vault itself as admin | **Fixed** | — |
| I-f | Info | Bytecode figure in docs out of date | **Fixed** (23,271 B) | — |

Residual items for a professional audit / formal verification: storage compatibility of every future release, a formal proof that only `scheduleUpgrade` operations can set the implementation slot, correctness of each release's `_migrate` across skip paths, guardian/recovery liveness game theory, registry-owner key setup, chain-specific `codehash`/`extcodecopy` behaviour.

### 1d. Agent sessions — review round 4

Scope: envelopes, session manager, `openSession`, per-session budgets (commit 05b15ed and follow-ups). The core guarantee held: with a compromised session manager **and** compromised session keys, the vault-wide limit, every session budget and the destination allowlist were never exceeded.

| ID | Severity | Finding | Status | Regression test |
|---|---|---|---|---|
| F1 | Medium | Envelope ids ≥ 2^64 were truncated when stored, so a session could run on another envelope's calls/budgets and escape "envelope off" | **Fixed** — such ids are rejected | `test_largeEnvelopeIdsAreRejected` |
| F2 | Medium | The session manager could revoke ordinary policies (availability) | **Fixed** — it may close sessions only | `test_managerCannotRevokeOrdinaryPolicies` |
| F3 | Low | Sessions and policies shared one id counter (timelocked follow-ups could hit a session); per-policy timelocked changes could widen a session beyond its envelope | **Fixed** — sessions use ids from 2^128 (`nextSessionId`); `updatePolicy`/`setAgent`/`setCall`/`setPolicyActive` refuse sessions (`IsSession`) | `test_sessionsHaveTheirOwnIdsAndCannotBeWidened` |
| F4 | Low | `disallowCall` on a session silently did nothing | **Fixed** — refused (`IsSession`); narrow the envelope or revoke the session | `test_disallowCallOnASessionIsRefused` |
| F5 | Low | Lowering an envelope's value cap / max TTL did not reach open sessions | **Fixed** for the value cap (applied live); `maxTtl` documented as limiting new sessions (use revoke / envelope off for open ones) | `test_loweringTheValueCapAppliesToOpenSessions` |
| F6 | Low | Re-activating an envelope revived the sessions it had stopped | **Fixed** — envelope `generation` is bumped on every switch-off; older sessions stay dead | `test_reactivatingAnEnvelopeDoesNotReviveSessions` |
| D1 | Design | The admin key could open sessions and so spend instantly | **Fixed** — only the session manager opens sessions | `test_adminCannotOpenSessions` |
| D4 | Design | Sessions could be opened before `finalizeSetup` | **Fixed** | `test_noSessionsBeforeSetupIsFinished` |
| D5 | Design | Session manager could also be admin / guardian / recovery | **Fixed** — roles are kept apart in every setter | `test_sessionManagerRoleSeparation` |
| D2, D3 | Design | A compromised manager can open many sessions (bounded only by the vault-wide limit) and is back after an unpause | **Documented** — playbook: remove the manager (instant) + `panic` or switch the envelope off; envelope-wide aggregate budgets are a candidate for a later release | — |
| D7–D10 | Info | Internal getters (events for operations; SDK hardcodes the EIP-712 name/version), `budgetAvailable` ignores session status, inflows can offset outflows | **Documented** | — |

## 2. Verified as sound by the review

- No path around `onlyTimelocked`: no delegatecall; `execute`/`setCall` reject the vault as target; `execute` and `executeScheduled` share one reentrancy lock; timelocked functions make no external calls.
- Tracked-asset list cannot change during `execute`, so before/after balance arrays always line up.
- Bucket math: available never exceeds `maxPerWindow`, no overflow, rounding favours the vault; `lowerAssetLimit` cannot increase what can be spent.
- Signatures: EIP-712 domain includes chain id (recomputed after a fork) and the vault address; per-policy nonces; high-s rejected; no replay across vaults or chains.
- Guardians have no function that moves funds or loosens rules.
- Factory: CREATE2 salt bound to the caller; the address commits to all constructor arguments.

## 3. Residual risks and design limitations

1. **Generic calls**: only `transfer`, `transferFrom`, `approve`, `increaseAllowance`, `setApprovalForAll` are inspected. Any other allowlisted `(target, selector)` can direct its effect anywhere (swaps with a `to` argument, lending `withdraw(…, to)`, bridges, `Permit2.approve`, ERC-777 operators, multicall routers). For tracked assets the outflow limit still bounds the loss. **Allowlist such calls only with a validator that checks their arguments.**
2. **Only the vault's own balances of tracked assets are measured**: positions in other tokens (aTokens, LP/vault shares), debt, untracked tokens and NFTs are not limited. Track every asset the vault holds.
3. **Net accounting per batch**: inflows in the same batch offset outflows. Tokens with privileged movers (issuer seizure, blacklist burns, rebasing) move funds outside the vault's control.
4. **`coSignAbove` applies per `execute`**: a payment can be split into several calls; only the window limit bounds the total.
5. **Colluding guardians**: two rogue guardians can protect each other from removal and keep the vault frozen (denial of service, never theft). Choose guardians on independent infrastructure.
6. **Admin + all guardians compromised**: rules can be loosened after the delay. Lost admin + no recovery key = no recovery; lost admin + a rogue guardian vetoing recovery = stuck.
7. **Before `finalizeSetup`** the admin has instant full control of the configuration (no funds can move yet). Operations scheduled during setup still run after it.
8. **After a panic every policy is dead** for good; re-creating policies, agents and calls takes at least one delay.
9. **An agent can front-run a panic** and spend what is left in the current window.
10. **One operator key shared across vaults** means one compromise hits all of them (each within its own limit).

## 4. Test evidence

Commands (Foundry 1.5.1, solc 0.8.24, via-IR):

```bash
forge test
forge test --match-path "test/v2/*"
FOUNDRY_PROFILE=coverage forge coverage --ir-minimum --match-path "test/v2/*" --report summary
```

Results on 2026-11-06:

- Whole repository: **322 / 322 tests passing** (v1: 202, v2: 120).
- Agent sessions: 24 unit tests + 3 stateful invariants with a compromised session manager and compromised session keys (`test/v2/EPKVault.sessions.t.sol`).
- Static analysis: Slither reports **0** results on `contracts/v2/` — every original finding fixed or justified with proof tests, see [SLITHER_TRIAGE.md](SLITHER_TRIAGE.md); reentrancy and native-transfer proofs in `test/v2/EPKVault.reentrancy.t.sol`.
- v2 unit + fuzz: 55 passing; fuzz tests at 257 runs each, including `testFuzz_compromisedOperatorCannotDrain` (operator signer, agent and co-signer all compromised).
- v2 upgrade mechanism: 27 unit/fuzz + 2 stateful invariants (`test/v2/EPKVault.upgrade.t.sol`), see [EPK_V2_UPGRADE_ARCHITECTURE.md §10](EPK_V2_UPGRADE_ARCHITECTURE.md#10-test-evidence).
- v2 stateful invariants: 4 passing, 64 runs × depth 60 (3 840 attacker actions each), with a check that the attacker achieved successful executions in every run:
  - `invariant_outflowNeverExceedsTheLimit`
  - `invariant_noAllowanceSurvives`
  - `invariant_attackerGetsNothing`
  - `invariant_onlyAllowlistedDestinationsReceive`
- Coverage (v2 tests, `--ir-minimum`): see section 5.

## 5. Coverage

`FOUNDRY_PROFILE=coverage forge coverage --ir-minimum --match-path "test/v2/*" --report summary`:

| File | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| `contracts/v2/EPKVault.sol` | 97.09% (501/516) | 94.48% (684/724) | 82.86% (116/140) | 100% (95/95) |
| `contracts/v2/EPKRegistry.sol` | 100% (46/46) | 94.44% (51/54) | 75.00% (9/12) | 100% (9/9) |
| `contracts/v2/EPKVaultFactory.sol` | 100% (17/17) | 95.00% (19/20) | 50.00% (1/2) | 100% (5/5) |

With via-IR + `--ir-minimum`, Foundry's source maps under-report some branches (same artifact as noted for v1); the uncovered remainder is mostly defensive `revert` paths (e.g. zero-address and malformed-calldata checks).

## 6. Before mainnet

1. Independent audit by a professional firm (scope: this document's contracts + SDK signing code).
2. Public testnet deployment and a bug bounty.
3. Monitoring bot as a guardian (auto-cancel unexpected `OperationScheduled`, auto-`panic` on anomalies).
4. Integration validators for every generic call that will be allowlisted (DEX, lending, bridges).
