# Slither triage — EPK v2

Slither runs on **every pull request and every push to `master`** (`.github/workflows/security.yml`) and must stay on.
This page records how each finding on the EPK v2 code (`contracts/v2/`) was handled.

Rules for this codebase:

1. A finding is **fixed in code** whenever the code can be improved.
2. A finding may be **suppressed only** with an inline `slither-disable-start/end <detector>` range
   around the single function concerned, a one-line reason next to it, an entry in the table below
   and — for medium/high detectors — a test that proves the scenario is not exploitable.
3. Never `slither-disable … all`, never repository-wide exclusions.

Tool: Slither 0.11.6, `slither . --foundry-out-directory out --exclude-dependencies`.

## Result

| | Before | After |
|---|---|---|
| Slither results on `contracts/v2/` | **36** (2 high, 5 medium, 16 low, 13 informational) | **0** |
| Fixed in code | — | 15 of the 36 (+ 3 of 4 new ones surfaced while refactoring) — §1 |
| Suppressed with justification (+ proof tests for the highs) | — | 21 of the 36 (+ 1 new) — §2 |

Verified locally on 2026-11-07: `0 result(s) found` for `contracts/v2/`; the full test suite of that day
(including all v2 fuzz and invariant tests) passed after the changes. Re-run on 2026-11-08 after the fifth review
(guard fixes): 0 results.

**Current state (2026-11-19, release 2.4.0, the code frozen for the audit): 27 results, all explained in §2e.**
All 27 are in the emergency module that arrived with 2.3.0 (`EPKVaultEmergency`, which shares the vault's storage
layout `EPKVaultLayout`) and in the vault's `fallback` that reaches it; none is in the 2.4.0 changes. They are
explained here rather than marked inline, because any edit to `EPKVault.sol` — even a comment — changes the
compiled metadata, and the frozen source must keep matching the 2.4.0 contracts deployed on the test networks byte
for byte. The inline markers come with the next code change (e.g. an audit fix).

## 1. Fixed in code

| Detector | Where | Fix |
|---|---|---|
| reentrancy (medium) | `_authorize` | nonce is now consumed **before** the external validator call (checks-effects-interactions); signatures are unaffected because the digest still uses the pre-increment nonce |
| incorrect-equality | `cancel`, `executeScheduled`, `_schedule` | existence is tested on the operation's release `version` (never 0), not on the timestamp-derived `readyAt` |
| incorrect-equality | `EPKRegistry.revokeRelease`, `_list` | "listed" is tested on `version != 0` |
| assembly | `_recover` | replaced by OpenZeppelin `ECDSA.tryRecoverCalldata` (65-byte signatures, low-s) |
| assembly | `_bubble` | replaced by OpenZeppelin `Address.verifyCallResult` |
| assembly | `_uintArg` | calldata slice instead of `calldataload` |
| assembly | `EPKRegistry._list` | `implementation.code[0]` instead of `extcodecopy` |
| uninitialized-local | `_settleOutflows.coSigned`, `schedule.shielded`, `EPKRegistry._list.version` | explicit initial values |
| costly-loop | `untrackAsset` | the array `pop()` moved out of the loop |
| cyclomatic-complexity | `_checkCall` (17) | token rules split into `_checkTokenCall` |
| missing-inheritance | `EPKRegistry`, `EPKVault` | interfaces moved to `contracts/v2/IEPK.sol`; `EPKRegistry is IEPKRegistry`, `EPKVault is IVersionedVault` |
| redundant-statements | `_migrate` | unnamed parameter |
| too-many-digits | `NATIVE_TRANSFER_SELECTOR` | `bytes4(0)` |
| missing-zero-check | `EPKRegistry.transferOwnership` | rejects `address(0)` |
| unused-return | `executeScheduled`, `_runCalls` | the return of `Address.verifyCallResult` is used |

Side effect: `EPKVault` bytecode went from 23,271 B to 21,329 B (margin to the 24,576 B limit: 3,247 B).

## 2. Suppressed with justification

### HIGH — `arbitrary-send-eth` in `_runCalls`

*Slither:* "sends eth to arbitrary user".

*Why it is safe:* sending value to the batch targets **is** the vault's job. Before `_runCalls` runs, `_checkCall` has already required for every call:

- `(target, selector)` allowlisted for the policy (timelocked to add);
- `value <= maxValuePerCall`;
- the native asset is tracked and the target is an **allowlisted destination** (timelocked to add, instant to remove);
- the whole batch is signed by the policy signer (EIP-712, bound to agent, nonce, deadline, vault, chain) and submitted by an allowed agent.

Afterwards the real outflow is charged against the per-window limit.

*Proof:*

- `testFuzz_nativeValueOnlyToAllowlistedDestinations` — 256 random targets with the call allowed and a valid signature: always `DestinationNotAllowed`, target balance 0;
- `test_nativeToDestinationWorksAndIsLimited`, `test_nativeSendNeedsSignerAndAgent`;
- invariants `invariant_attackerGetsNothing`, `invariant_outflowNeverExceedsTheLimit`.

### HIGH — `reentrancy-eth` in `execute`

*Slither:* state variables written after external calls.

*Why it is safe:* the state written after the batch is the outflow accounting (`assets[*].available/lastUpdate`). By design it must measure balances **after** the batch has run. Protection:

- `execute` holds the `nonReentrant` lock shared with `executeScheduled`;
- the nonce is consumed before any external call;
- every other state-changing entry point is restricted to the admin, guardians, recovery key or the vault itself (`onlyTimelocked`). A call target is none of these unless the admin made it a guardian — and guardians can only tighten.

*Proof:* `test/v2/EPKVault.reentrancy.t.sol`

- `test_reentrancy_unprivilegedTargetCannotReenterAnything` — a batch target tries 17 entry points mid-batch. One of them is a **fully valid, pre-signed batch** of its own. All 17 fail; the outer outflow is charged exactly once. Afterwards the same inner batch succeeds on its own, so the reentrancy lock is what stopped it;
- `test_reentrancy_guardianTargetCanOnlyTighten` — a target that is a guardian can lower the limit and pause mid-batch, but cannot unpause, add destinations, raise limits or upgrade; the outer outflow is still charged after its tightening;
- `test_reentrancyBlocked` (re-entry into `execute`).

### Low / informational (by design)

| Detector | Function(s) | Reason |
|---|---|---|
| `timestamp` | `executeScheduled`, `_loadExecutablePolicy`, `_settleOutflows`, `_available`, `_schedule`, `_isLive`, `lowerAssetLimit`, `setAsset`, `EPKRegistry.isApproved` | delays, deadlines and limit refills are minutes to weeks; a few seconds of validator skew are irrelevant |
| `timestamp` | `cancel`, `_exists`, `EPKRegistry._list` | false positive: only the `version` sentinel is compared; Slither taints the whole struct because it also stores a time |
| `incorrect-equality` | `EPKRegistry.isApproved` | intentional strict comparisons: "listed" sentinel and the codehash pin |
| `low-level-calls` | `executeScheduled` | self-call into the vault's own `onlyTimelocked` functions; result checked and bubbled |
| `low-level-calls` | `_runCalls` | arbitrary calldata must be forwarded; result checked and bubbled |
| `low-level-calls` | `_isValidSignature` | `staticcall` so the ERC-1271 answer can be checked to be exactly the 32-byte magic (a high-level call would revert on malformed answers) |
| `calls-loop` | `_authorize`, `_runCalls`, `_requireAllowancesCleared`, `_balanceOf` | loops bounded by `MAX_CALLS` / `MAX_TRACKED_ASSETS` over contracts chosen by the vault's own admin; a reverting one only blocks that vault's own operation |
| `unused-return` | `_recoverOrZero` | the third value of `tryRecoverCalldata` is a diagnostic error argument; any error means "no valid ECDSA signature" |
| `reentrancy-no-eth`, `reentrancy-benign`, `reentrancy-events` | `execute` | same analysis as `reentrancy-eth` above |

## 2b. Agent sessions (2026-11-07)

Adding agent sessions first produced 10 new results: `timestamp` / `incorrect-equality` on functions that read the `policies` struct (`_checkCall`, `_isValidSignature`, `_authorize`, `_requirePolicy`, `budgetAvailable`) and `cyclomatic-complexity` on `_loadExecutablePolicy`. Root cause: the session expiry was computed from `block.timestamp` and stored in the policy, so Slither tainted every policy field. **Fixed in code, no new suppressions**:

- `openSession` takes an absolute `validUntil`, which is only *checked* against the envelope's max TTL;
- the agent check moved into `_requireAgent`.

Slither again reports `0 result(s) found` on `contracts/v2/`.

## 2c. Guards and vault 2.1.0 (2026-11-07, branch `feature/epk-v2.1`)

DexGuard, ThreatFeedGuard, CompositeGuard and the vault 2.1.0 changes first produced 10 new results,
all in the guards (none in `EPKVault`).

| Detector | Where | Handling |
|---|---|---|
| `uninitialized-local` (×3) | `DexGuard._decodeV2` | **Fixed**: locals initialised explicitly |
| `incorrect-equality` | `ThreatFeedGuard.executeUnblock` | Suppressed: `readyAt == 0` is the "nothing scheduled" sentinel, not a balance (`test_unblockWaitsAndCanBeVetoed`) |
| `unused-return` | `DexGuard._price` | Suppressed: `startedAt` of `latestRoundData` is not needed; `updatedAt` bounds staleness (`test_price_staleRoundsFutureAndZero`) |
| `missing-zero-check` | `DexGuard` constructor | Suppressed: `wrappedNative = 0` is a valid setting (native swaps are then refused) |
| `calls-loop` | `DexGuard` constructor | Suppressed: token / feed decimals are read once per configured token at deployment |
| `assembly` | `DexGuard._addressAt` | Suppressed: read-only, memory-safe 20-byte load, bounds checked by the caller (`test_v3_rules`) |
| `cyclomatic-complexity` | `DexGuard._decodeV2` | Suppressed: one flat branch per supported V2 function, on purpose |
| `timestamp` | `DexGuard._checkSwap`, `_price`; `ThreatFeedGuard.executeUnblock` | Suppressed: deadlines, feed staleness and unblock delays are minutes to days |

Slither again reports `0 result(s) found` on `contracts/v2/` (40 contracts, 102 detectors).

After test-network delays and parallel upgrade clocks (`EPKChains`, commit `c6fbaf4`): still `0 result(s) found`
(41 contracts, 102 detectors, clean build), no new suppressions.

Note for Windows: if Python or an editor rewrites a `.sol` file with CRLF line endings, Slither's line
numbers shift and inline suppressions stop matching. Keep the working copy of `contracts/` in LF and run
`forge clean` before the check.

## 2d. Fast track for urgent fixes (2026-11-18, vault 2.4.0)

| Detector | Where | Handling |
|---|---|---|
| `assembly` | `EPKVault.scheduleUpgrade` | Suppressed: one read-only `staticcall` to the vault's own registry (`isUrgent`), scratch space only (memory-safe); a failed call or an answer shorter than 32 bytes counts as "not urgent". Written in assembly because `try/catch` cost about 100 bytes more and EPKVault must keep 100 bytes under EIP-170 (`test_vaultKeepsAtLeast100BytesUnderEIP170`; behaviour in `test/v2/EPKRegistry.fastTrack.t.sol`) |
| `missing-zero-check` | `EPKRegistry` constructor (`council`) | Suppressed: `council = address(0)` is a valid setting — no council, no fast track (`test_noCouncilNoFastTrack`) |

GitHub's code-scanning run of Slither on PR VOVAN1980/ibiti-epk-core#28 reported exactly one new result, the
`missing-zero-check` above; the assembly suppression held. Local run before the audit freeze: §2e.

## 2e. Emergency module (2.3.0), triaged on 2026-11-19

Local run: `27 result(s) found` (35 contracts, 102 detectors) on the merge commit of
VOVAN1980/ibiti-epk-core#29. GitHub's code-scanning run (no path filter) shows the same 27 plus the two
`EPKRegistry` / `scheduleUpgrade` results of §2d, which are marked inline.

| Detector | Count | Where | Handling |
|---|---|---|---|
| `reentrancy-eth` | 1 | `EPKVaultEmergency.evacuate` | False positive: `evacuate` takes the vault's own lock (`_locked`, shared with `execute` / `executeScheduled`) before any call; `_locked = false` after the calls is the lock's release. The only recipient is the owner's cold wallet, set through the timelock. Proof: `test_E8_reentrantColdWalletIsRefused` |
| `uninitialized-state` | 8 | `EPKVaultLayout` (`admin`, `recovery`, `isGuardian`, `coSigner`, `setupDone`, `assets`, `_trackedAssets`, `sessionManager`) as used by `EPKVaultEmergency` | False positive: the module only runs through the vault's `delegatecall`, on the vault's storage, which the vault initializes. Called directly it has no admin and no assets, so every call fails (`test_moduleCalledDirectlyDoesNothing`) |
| `constable-states` | 12 | `EPKVaultLayout` | False positive, same reason: these are the vault's storage slots, mirrored so the module writes the same layout. Making them constant would break the append-only storage layout of an upgradeable vault |
| `unused-state` | 1 | `EPKVaultLayout.operations` in `EPKVaultEmergency` | Kept on purpose: the slot is part of the shared layout; removing it would shift every later slot |
| `incorrect-equality` | 2 | `EPKVaultEmergency.evacuate` | Not a balance check: `amount == 0` skips an empty asset; `ret.length == 0` accepts tokens whose `transfer` returns nothing (USDT-style). A failed transfer reverts (`TokenCallFailed`) |
| `missing-zero-check` | 2 | `EPKVaultEmergency.setColdWallet`, `setEvacuator` | Valid on purpose: `address(0)` switches evacuation off (`evacuate` then reverts `NoColdWallet`) or removes the optional evacuator (`test_separateKeysAreEnforced`: switching the evacuator off is always possible); both run only through the timelock |
| `assembly` | 1 | `EPKVault.fallback` | Justified in the code next to it: one `delegatecall` to `_emergency`, an immutable deployed by the implementation's own constructor. The existing `slither-disable-next-line` comment sits two lines above `fallback()` (a plain comment line is in between), so Slither does not apply it; moved with the next code change |

## 3. How to reproduce

```bash
python -m venv .venv-slither
.venv-slither/Scripts/pip install slither-analyzer   # or bin/pip on Linux/macOS
forge build
.venv-slither/Scripts/slither . --foundry-out-directory out --exclude-dependencies --filter-paths "test/|lib/|scripts/"
```

Every future change to `contracts/v2/` must keep this run free of unexplained findings.
