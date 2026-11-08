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

## 3. How to reproduce

```bash
python -m venv .venv-slither
.venv-slither/Scripts/pip install slither-analyzer   # or bin/pip on Linux/macOS
forge build
.venv-slither/Scripts/slither . --foundry-out-directory out --exclude-dependencies --filter-paths "test/|lib/|scripts/"
```

Every future change to `contracts/v2/` must keep this run free of unexplained findings.
