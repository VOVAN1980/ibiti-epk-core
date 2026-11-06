# EPK v2 (EPKVault) — Internal Security Review

| | |
|---|---|
| Scope | `contracts/v2/EPKVault.sol`, `contracts/v2/EPKVaultFactory.sol` |
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

- Whole repository: **261 / 261 tests passing** (v1: 202, v2: 59).
- v2 unit + fuzz: 55 passing; fuzz tests at 257 runs each, including `testFuzz_compromisedOperatorCannotDrain` (operator signer, agent and co-signer all compromised).
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
| `contracts/v2/EPKVault.sol` | 96.74% (386/399) | 93.15% (517/555) | 80.56% (87/108) | 100% (68/68) |
| `contracts/v2/EPKVaultFactory.sol` | 100% (10/10) | 100% (10/10) | — | 100% (3/3) |

With via-IR + `--ir-minimum`, Foundry's source maps under-report some branches (same artifact as noted for v1); the uncovered remainder is mostly defensive `revert` paths (e.g. zero-address and malformed-calldata checks).

## 6. Before mainnet

1. Independent audit by a professional firm (scope: this document's contracts + SDK signing code).
2. Public testnet deployment and a bug bounty.
3. Monitoring bot as a guardian (auto-cancel unexpected `OperationScheduled`, auto-`panic` on anomalies).
4. Integration validators for every generic call that will be allowlisted (DEX, lending, bridges).
