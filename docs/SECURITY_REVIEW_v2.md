# EPK v2 (EPKVault) — Internal Security Review

| | |
|---|---|
| Scope | `contracts/v2/EPKVault.sol`, `contracts/v2/EPKVaultFactory.sol`, `contracts/v2/EPKRegistry.sol` (upgrade mechanism: second round, §1b) |
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
forge coverage --ir-minimum --match-path "test/v2/*" --report summary
```

Results on 2026-11-06:

- Whole repository: **283 / 283 tests passing** (v1: 202, v2: 81).
- v2 unit + fuzz: 55 passing; fuzz tests at 257 runs each, including `testFuzz_compromisedOperatorCannotDrain` (operator signer, agent and co-signer all compromised).
- v2 upgrade mechanism: 20 unit/fuzz + 2 stateful invariants (`test/v2/EPKVault.upgrade.t.sol`), see [EPK_V2_UPGRADE_ARCHITECTURE.md §10](EPK_V2_UPGRADE_ARCHITECTURE.md#10-test-evidence).
- v2 stateful invariants: 4 passing, 64 runs × depth 60 (3 840 attacker actions each), with a check that the attacker achieved successful executions in every run:
  - `invariant_outflowNeverExceedsTheLimit`
  - `invariant_noAllowanceSurvives`
  - `invariant_attackerGetsNothing`
  - `invariant_onlyAllowlistedDestinationsReceive`
- Coverage (v2 tests, `--ir-minimum`): see section 5.

## 5. Coverage

`forge coverage --ir-minimum --match-path "test/v2/*" --report summary`:

| File | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| `contracts/v2/EPKVault.sol` | 96.71% (412/426) | 93.28% (555/595) | 80.87% (93/115) | 100% (76/76) |
| `contracts/v2/EPKRegistry.sol` | 93.75% (45/48) | 90.91% (50/55) | 81.82% (9/11) | 100% (9/9) |
| `contracts/v2/EPKVaultFactory.sol` | 100% (17/17) | 95.00% (19/20) | 50.00% (1/2) | 100% (5/5) |

With via-IR + `--ir-minimum`, Foundry's source maps under-report some branches (same artifact as noted for v1); the uncovered remainder is mostly defensive `revert` paths (e.g. zero-address and malformed-calldata checks).

## 6. Before mainnet

1. Independent audit by a professional firm (scope: this document's contracts + SDK signing code).
2. Public testnet deployment and a bug bounty.
3. Monitoring bot as a guardian (auto-cancel unexpected `OperationScheduled`, auto-`panic` on anomalies).
4. Integration validators for every generic call that will be allowlisted (DEX, lending, bridges).
