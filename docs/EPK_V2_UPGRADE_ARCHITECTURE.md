# EPK v2 — Upgrade Architecture

Status: **implemented (EPK 2.0 and 2.1), internally reviewed (3 rounds), not audited; live on BSC Testnet only, not on any mainnet.**
Contracts: `contracts/v2/EPKVault.sol`, `contracts/v2/EPKRegistry.sol`, `contracts/v2/EPKVaultFactory.sol` (incl. `EPKVaultProxy`).
Tests: `test/v2/EPKVault.upgrade.t.sol`. Storage snapshots: `docs/storage-layout/EPKVault-2.0.0.txt`, `docs/storage-layout/EPKVault-2.1.0.txt`.

## 1. The short answer

> *"After mainnet, can we modernize EPK without redeploying?"*

- **New logic is always deployed once** as a new implementation contract — code that does not exist on-chain cannot run.
- **Customer vaults are not redeployed and funds never move.** Each vault lives at a permanent proxy address and can switch to a newer implementation **by its own decision**.
- **Nobody — including IBITI Labs — can switch a vault for its owner**, disable its protection, or reach its funds.

## 2. Requirements

1. Every customer has one `EPKVault` with a **permanent address**.
2. New protection modules / validators can be attached **without moving funds**.
3. New versions are deployed separately; **old versions keep working** (no forced upgrades).
4. **No single key** (IBITI or anyone) can replace a vault's logic, disable protection or access funds.
5. Critical changes need authorization **and** a delay; the **emergency stop is always available**.

## 3. Options compared

| | A. Immutable vault + modules | **B. Per-vault UUPS, opt-in, registry-gated (chosen)** | C. Beacon proxy | D. Migrate to a new vault |
|---|---|---|---|---|
| Vault address after a core upgrade | changes | **kept** | kept | changes |
| Funds move | yes (migration) | **no** | no | yes |
| Who can change a vault's code | nobody | **only that vault: admin → ≥ 2 days → any guardian or the recovery key can veto** | **one beacon owner for ALL vaults** | n/a |
| Single key risk | none | none (registry alone or admin alone is not enough) | **critical** | none |
| Forced upgrades possible | no | **no** | yes | no |
| Push an urgent fix to everyone | no | no (owners opt in; guardians can `panic` meanwhile) | yes | no |
| Audit surface | smallest | medium (proxy + upgrade path) | medium | small |
| Cost to create a vault | full contract (~4.7M gas) | **tiny proxy (140 B runtime)** | tiny | full contract |
| Typical failure modes | none from upgrades | storage collision, bad release, migration bugs | mass compromise via beacon | slow migration under outflow limits |

**Decision: B**, combined with A for everything that modules can do. Beacon (C) is rejected: it gives one key power over every customer. Migration (D) remains the fallback for changes that cannot be done in place (§6).

## 4. Architecture

```
            IBITI Labs (multisig planned; testnet: one key)                  Customer
                  │ propose release (7-day public delay)     │ admin key
                  ▼                                          ▼
           ┌──────────────┐    isApproved / versionOf  ┌──────────────────────┐
           │ EPKRegistry  │◄───────────────────────────│ EPKVaultProxy        │
           │ (fixed per   │                            │ permanent address,   │
           │  vault)      │                            │ storage and funds    │
           └──────────────┘                            └──────────┬───────────┘
                                                                  │ delegatecall
                     ┌─────────────────────┬──────────────────────┼─────────────────┐
                     ▼                     ▼                      ▼                 ▼
              EPKVault 2.0.0        EPKVault 2.1.0          EPKVault 3.0.0     Validators /
              (genesis impl)        (opt-in)                (opt-in)           modules (per policy)
```

| Component | Role | Can it touch funds? |
|---|---|---|
| `EPKVault` implementation | logic; cannot be initialized itself (`_disableInitializers`) | no |
| `EPKVaultProxy` (one per customer) | ERC-1967 proxy: permanent address, storage, funds; accepts plain native transfers itself (2300-gas safe) | — |
| `EPKVaultFactory` | creates proxies only on a registry-approved implementation; caller becomes admin; **no owner, no upgrade power** | no |
| `EPKRegistry` | lists reviewed implementations; version read from the code; 7-day approval delay; instant revocation; codehash pinned; rejects EIP-7702 delegated code; **fixed per vault, cannot be swapped** | no — cannot upgrade, pause or call vaults |
| Validators / modules | per-policy extra rules, swapped through the vault timelock | no |
| Guardians (≥ 2, recommended ≥ 3) | veto pending changes, `panic` | no |
| Recovery key (optional, recommended) | replace a lost/compromised admin; veto pending changes | no |

## 5. Upgrade flow

1. IBITI deploys the new implementation (e.g. `EPKVault 2.1.0`), publishes source, audit report and storage-layout diff.
2. IBITI calls `registry.proposeRelease(impl)`. The registry reads the version from `impl.vaultVersion()` (must be higher than the latest, by at most one major step) and pins the codehash. The release is **usable only after 7 days** (public review window).
3. A customer who wants it: admin calls `vault.scheduleUpgrade(impl, salt)` — from 2.1.0 this may happen **during** the release window: both clocks run in parallel, so a new release reaches a vault in 7 days, not 7 + 2.
   - Rejected immediately if the release is not listed or not newer than the current version.
   - Waits **max(2 × vault delay, 2 days)** — the floor holds even if the delay was lowered first. Visible as `OperationScheduled`.
   - The code can still only run once the registry approves it (step 4): scheduling early never shortens the public review window, and a release revoked during its window can never be installed.
   - Any guardian **or the recovery key** can `cancel`; `panic` / `revokeAll` invalidate it.
4. After the delay the **admin** calls `executeScheduled(vault.upgradeOperationData(impl), salt)`. `_authorizeUpgrade` re-checks: called by the vault itself, release still approved (not revoked), version still newer.
5. The proxy points at the new code and the release's migration **always** runs once: the base `migrate()` (not overridable) checks that the caller is the vault itself and passes the version the vault is coming **from** to the release's `_migrate(from)`, which runs every missing step. A release without `_migrate` cannot be installed.
6. Address, funds, roles, policies, nonces, limits stay. **Ordinary operations still pending from the old release become stale** and must be scheduled again under the new rules; recovery operations and shielded guardian changes survive.

**Public test networks (from 2.1.0, `contracts/v2/EPKChains.sol`).** The same code uses minute-scale
delays on BNB Smart Chain Testnet (97) and Ethereum Sepolia (11155111): release window 5 minutes, upgrade
wait 5 minutes (in parallel), so a full release → schedule → upgrade cycle is testable in about 5 minutes.
Every other chain — every mainnet, unknown chains and local test chains (31337) — gets the production delays
(7 days, 2-day floor, 1-hour minimum timelock), so the test suite always exercises the real rules. Existing
vaults keep the rules of the code they run; nothing here can shorten them.

Things that are **impossible**: calling `upgradeToAndCall` directly (any caller), scheduling it or `migrate()` through the generic `schedule`, attaching any code other than the release's own migration, calling `migrate()` from outside, swapping the vault's registry, downgrading, installing an unlisted / revoked / not-yet-active implementation, re-initializing a proxy or the implementation, the recovery key executing the admin's operations, a pending operation from one release running under another.

## 6. What can change without migration

| Change | How | Vault redeploy? |
|---|---|---|
| Limits, destinations, policies, agents, co-signer, guardians, recovery | vault configuration (tighten instantly, loosen via timelock) | no |
| New protection rules (DEX/bridge validators, ThreatFeed V2, anomaly checks) | new validator module, attached via timelocked `updatePolicy` | no |
| New core features (session envelopes, new call checks, ERC-4337/7579 compatibility, gas optimizations, bug fixes) | new implementation + opt-in upgrade | no |
| Storage-incompatible redesign, other proxy standard, another registry, another chain | new vault + migration (timelocked, within outflow limits) | **yes** |

## 7. Trust model

| Party | Compromised alone → worst case |
|---|---|
| IBITI registry owner | can list a malicious release (public for 7 days — 5 minutes on test networks — one major step at most), revoke releases, or permanently freeze the registry (no succession). Vaults keep working on their current release; new upgrades would need new vaults. **Cannot upgrade any vault, cannot touch funds.** |
| Vault admin | can schedule loosening changes / an upgrade to an *approved* release; they are visible for ≥ delay (≥ 2 days for upgrades) and any other guardian or the recovery key can veto. **Cannot install unapproved code, cannot swap the registry, cannot squat the recovery.** |
| Guardian | denial of service (pause, veto). Cannot move funds; cannot block its own removal. |
| Recovery key | can schedule an admin change (2× delay, guardians can veto) and veto pending changes (denial of service). Cannot execute admin operations, cannot move funds. |
| Operator signer / agent / co-signer | bounded by outflow limits and destination allowlist. |

**Takeover threshold.** Because removing a guardian is shielded from that guardian (so one rogue guardian cannot freeze the vault), a compromised admin can replace an honest guardian **unless another honest, online guardian or the recovery key vetoes it** within the delay. With 2 guardians and no recovery key, a compromised admin plus **one** absent guardian is enough. Therefore: use **≥ 3 independent guardians and a recovery key**, and a monitoring bot as one of the guardians. After such a takeover, everything (including an upgrade to an approved release) still takes ≥ the delays above.

## 8. Threats and mitigations

| Threat | Mitigation |
|---|---|
| Storage collision between versions | append-only layout in one contract (no inherited state; OZ 5 uses ERC-7201 namespaced storage; slots 0–22, no overlap with ERC-1967 / `Initializable`); snapshot `docs/storage-layout/EPKVault-2.0.0.txt`; every release must diff against it (struct members too) |
| Initializer takeover | implementation runs `_disableInitializers()`; proxies are initialized in the same transaction they are created; `initialize` rejects the vault itself as admin / guardian / recovery |
| Migration called by an outsider | base `migrate()` is not overridable and requires the vault itself as caller; only attachable via `scheduleUpgrade` |
| Migration step lost when a vault skips a release | `_migrate(from)` receives the version captured **before** `reinitializer(n)` runs and must run every missing step |
| Arbitrary code attached to an upgrade | the only payload is the release's own `migrate()` |
| Operation scheduled under one release runs under another | operations record the release version; ordinary ones go stale on upgrade |
| Admin squats the recovery operation's id | a recovery operation replaces a look-alike ordinary operation; the admin cannot replace or cancel a recovery operation |
| Admin poisons the recovery target (e.g. makes it a guardian first) | that change is itself timelocked; any guardian or the recovery key can veto it |
| Registry swapped for a fake one | not possible: the registry is fixed per vault |
| Release whose code lies about its version | the registry reads the version from the code itself |
| Version space exhausted by one proposal | at most one major step (`MAX_VERSION_STEP = 10_000`) per release |
| Bricking via a non-UUPS release | OZ `upgradeToAndCall` requires the new implementation's `proxiableUUID`; every release must keep `UUPSUpgradeable` |
| Malicious or buggy approved release | audit before listing, 7-day public window, instant revocation, per-vault opt-in with ≥ 2 days and veto, `panic` |
| Code at the release address changes | codehash pinned; EIP-7702 delegated accounts (`0xEF…`) rejected; implementations contain no `selfdestruct` |
| Upgrade faster than intended after lowering the delay | fixed floor `UPGRADE_DELAY_FLOOR = 2 days` |
| `pause` alone does not stop upgrades | `panic` / `revokeAll` invalidate pending upgrades; a new upgrade scheduled afterwards again needs ≥ 2 days, and monitoring must veto it again |
| New vaults on a revoked (buggy) release | the factory refuses to create vaults on a non-approved implementation |
| Payers using `transfer` / `send` (2300 gas) | `EPKVaultProxy.receive()` accepts native coins without delegating |
| The vault as its own signer / validator / co-signer | rejected |
| Vault owners who never upgrade keep a known bug | no forced upgrades by design; IBITI notifies; guardians can `panic` and admins tighten rules instantly |
| Domain separator behind a proxy | computed on every call from the proxy address and current chain id |

## 9. Rules for every future release

1. Storage: **append only** — state variables and struct members (`Policy`, `Asset`, `Operation`, …); diff `forge inspect EPKVault storageLayout` against the latest snapshot; commit a new snapshot.
2. Override `vaultVersion()` (`major*10000 + minor*100 + patch`), strictly higher, at most one major step.
3. Migration: override `function _migrate(uint64 from) internal override reinitializer(n)` and run every step `from` has not reached yet (`if (from < 2) {…} if (from < 3) {…}`). Do **not** read `_getInitializedVersion()` inside `_migrate` (it already equals `n`). `migrate()` runs with the reentrancy lock held: it cannot call `execute` / `executeScheduled`.
4. Must keep: `UUPSUpgradeable`, `_authorizeUpgrade` rules, the upgrade delay floor, version-bound operations, timelock + veto, `panic`, recovery, outflow limits, destination allowlist. No `selfdestruct`, no `delegatecall` outside the upgrade path.
5. If the meaning of the signed `Execute` data changes, bump `EIP712_VERSION`.
6. Tests: full suite + an upgrade test from **every** previous release (including skipping releases) + invariants after upgrade.
7. Independent audit → `proposeRelease` → 7 days → announce.
8. Static analysis: Slither must report no unexplained findings ([SLITHER_TRIAGE.md](SLITHER_TRIAGE.md)).
9. Bytecode budget: `EPKVault` is 24,562 B of the 24,576 B limit (v2 is compiled with optimizer_runs = 1 for size). New features should go into validators/modules or external libraries; a release that does not fit must split logic before it can ship.

## 10. Test evidence

`test/v2/EPKVault.upgrade.t.sol` (27 unit/fuzz + 2 invariants):

- upgrade keeps address, funds and settings and runs the migration; `upgradeOperationData` matches;
- migrations: only by the vault itself on every release; a vault skipping 2.1.0 still gets its step (2.0.0 → 2.2.0); step-by-step upgrades run each step once; a release without a migration cannot be installed;
- pending ordinary operations go stale on upgrade while recovery operations survive;
- timing: needs 2× delay; the 2-day floor holds after lowering the vault delay;
- no direct or generic upgrade path (admin, guardians, attacker, registry, recovery key);
- unapproved / not-yet-active / revoked releases rejected; no downgrade; guardian veto and `panic` stop upgrades;
- recovery key vetoes a guardian replacement the guarded guardian itself cannot cancel; recovery replaces a squatted operation and cannot be squatted back; recovery cannot execute admin operations; registry owner cannot upgrade vaults;
- implementation and proxies cannot be re-initialized; the vault cannot be its own signer / validator / co-signer; factory refuses a revoked implementation; vault accepts 2300-gas `transfer` payments;
- registry: owner-only, version read from code, no lower/equal versions, max one major step, code required, must be a vault, no duplicates, rejects EIP-7702 delegated code, 2-step ownership;
- fuzz: `testFuzz_directUpgradeAlwaysFails` — any caller, any implementation;
- invariants (compromised admin keeps trying, incl. lowering the delay and generic scheduling; 64 runs × depth 40): `invariant_implementationIsAlwaysAnApprovedRelease`, `invariant_upgradeNeverFasterThanTheFloor`.

## 11. Not done yet

- Independent audit of the vault **and** the upgrade path; formal verification of "the only path that sets the implementation slot is a scheduled `scheduleUpgrade` operation".
- CI check that diffs the storage layout automatically.
- Registry-owner succession and a safe registry-migration path for vaults (today a vault's registry is fixed for life).
- Optional listing-time check of `proxiableUUID()`; the `0xEF` check would also reject EOF contracts if EOF ever ships.
- Recommended registry-owner setup: multisig behind its own timelock.
- ERC-5267 `eip712Domain()` for wallets.
