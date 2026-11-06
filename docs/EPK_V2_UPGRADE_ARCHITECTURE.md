# EPK v2 — Upgrade Architecture

Status: **implemented on `feature/epk-v2`, internally reviewed (2 rounds), not audited, not deployed anywhere.**
Contracts: `contracts/v2/EPKVault.sol`, `contracts/v2/EPKRegistry.sol`, `contracts/v2/EPKVaultFactory.sol` (incl. `EPKVaultProxy`).
Tests: `test/v2/EPKVault.upgrade.t.sol`. Storage snapshot: `docs/storage-layout/EPKVault-2.0.0.txt`.

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
6. EPK v1 stays fully working and untouched.

## 3. Options compared

| | A. Immutable vault + modules | **B. Per-vault UUPS, opt-in, registry-gated (chosen)** | C. Beacon proxy | D. Migrate to a new vault |
|---|---|---|---|---|
| Vault address after a core upgrade | changes | **kept** | kept | changes |
| Funds move | yes (migration) | **no** | no | yes |
| Who can change a vault's code | nobody | **only that vault: admin → ≥ 2 days (2× delay) → guardians can veto** | **one beacon owner for ALL vaults** | n/a |
| Single key risk | none | none (registry alone or admin alone is not enough) | **critical** | none |
| Forced upgrades possible | no | **no** | yes | no |
| Push an urgent fix to everyone | no | no (owners opt in; guardians can `panic` meanwhile) | yes | no |
| Audit surface | smallest | medium (proxy + upgrade path) | medium | small |
| Cost to create a vault | full contract (~4.6M gas) | **tiny proxy (140 B runtime)** | tiny | full contract |
| Typical failure modes | none from upgrades | storage collision, bad release, initializer bugs | mass compromise via beacon | slow migration under outflow limits |

**Decision: B**, combined with A for everything that modules can do. Beacon (C) is rejected: it gives one key power over every customer. Migration (D) remains the fallback for changes that cannot be done in place (§6).

## 4. Architecture

```
            IBITI Labs (multisig)                         Customer
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
| Guardians (≥ 2 per vault) | veto pending changes, `panic` | no |

## 5. Upgrade flow

1. IBITI deploys the new implementation (e.g. `EPKVault 2.1.0`), publishes source, audit report and storage-layout diff.
2. IBITI calls `registry.proposeRelease(impl)`. The registry reads the version from `impl.vaultVersion()` (must be higher than the latest, by at most one major step) and pins the codehash. The release is **usable only after 7 days** (public review window).
3. A customer who wants it: admin calls `vault.scheduleUpgrade(impl, withMigration, salt)`.
   - Rejected immediately if the release is not approved or not newer than the current version.
   - Waits **max(2 × vault delay, 2 days)** — the floor holds even if the delay was lowered first. Visible as `OperationScheduled`.
   - Any guardian can `cancel`; `panic` / `revokeAll` invalidate it.
   - `withMigration` can only attach the release's own parameterless `migrate()`; no other code rides along.
4. After the delay the **admin** calls `executeScheduled(vault.upgradeOperationData(impl, withMigration), salt)`. `_authorizeUpgrade` re-checks: called by the vault itself, release still approved (not revoked), version still newer.
5. The proxy points at the new code. Address, funds, roles, policies, nonces, limits stay. If requested, `migrate()` runs once (`reinitializer(n)` + vault-only caller).

Things that are **impossible**: calling `upgradeToAndCall` directly (any caller), scheduling it or `migrate()` through the generic `schedule`, attaching arbitrary code to an upgrade, calling a release's `migrate()` from outside, swapping the vault's registry, downgrading, installing an unlisted / revoked / not-yet-active implementation, re-initializing a proxy or the implementation, the recovery key executing the admin's operations.

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
| IBITI registry owner | can list a malicious release (public for 7 days, one major step at most) or revoke releases (blocks future opt-ins and new vaults). **Cannot upgrade any vault, cannot touch funds.** |
| Vault admin | can schedule loosening changes / an upgrade to an *approved* release; guardians see it for ≥ delay (≥ 2 days for upgrades) and can veto. **Cannot install unapproved code, cannot swap the registry.** |
| Guardian | denial of service (pause, veto). Cannot move funds; cannot block its own removal. |
| Recovery key | can schedule an admin change (2× delay, guardians can veto). Cannot execute admin operations. |
| Operator signer / agent / co-signer | bounded by outflow limits and destination allowlist. |
| Vault admin **and** all guardians | can loosen every rule after the delay — upgrades add no extra power here. |
| Registry owner **and** vault admin **and** all guardians | could install malicious code after 7 days + ≥ 2 days. Mitigation: independent parties, monitoring, audits. |

## 8. Threats and mitigations

| Threat | Mitigation |
|---|---|
| Storage collision between versions | append-only layout in one contract (no inherited state; OZ 5 uses ERC-7201 namespaced storage; verified: slots 0–16, no overlap with ERC-1967 / `Initializable`); snapshot `docs/storage-layout/EPKVault-2.0.0.txt`; every release must diff against it |
| Initializer takeover | implementation runs `_disableInitializers()`; proxies are initialized in the same transaction they are created; `initialize` rejects the vault itself as guardian / recovery |
| Migration called by an outsider | releases' `migrate()` = `reinitializer(n)` **and** `msg.sender == address(this)`; only attachable via `scheduleUpgrade` |
| Arbitrary code attached to an upgrade | the only possible payload is the release's own `migrate()` |
| Registry swapped for a fake one | not possible: the registry is fixed per vault |
| Release whose code lies about its version | the registry reads the version from the code itself |
| Version space exhausted by one proposal | at most one major step (`MAX_VERSION_STEP = 10_000`) per release |
| Bricking via a non-UUPS release | OZ `upgradeToAndCall` requires the new implementation's `proxiableUUID`; every release must keep `UUPSUpgradeable` |
| Malicious or buggy approved release | audit before listing, 7-day public window, instant revocation, per-vault opt-in with ≥ 2 days and guardian veto, `panic` |
| Code at the release address changes | codehash pinned; EIP-7702 delegated accounts (`0xEF…`) rejected; implementations contain no `selfdestruct` |
| Upgrade faster than intended after lowering the delay | fixed floor `UPGRADE_DELAY_FLOOR = 2 days` |
| New vaults on a revoked (buggy) release | the factory refuses to create vaults on a non-approved implementation |
| Payers using `transfer` / `send` (2300 gas) | `EPKVaultProxy.receive()` accepts native coins without delegating |
| Vault owners who never upgrade keep a known bug | no forced upgrades by design; IBITI notifies; guardians can `panic` and admins tighten rules instantly |
| Domain separator behind a proxy | computed on every call from the proxy address and current chain id |

## 9. Rules for every future release

1. Storage: **append only**; diff `forge inspect EPKVault storageLayout` against the latest snapshot; commit a new snapshot.
2. Override `vaultVersion()` (`major*10000 + minor*100 + patch`), strictly higher, at most one major step.
3. Migration: one cumulative `migrate()` per release — `reinitializer(n)`, `msg.sender == address(this)`, and run every missing step from `_getInitializedVersion()` up (vaults may skip releases). If the release changes scheduling rules, bump `epoch` in the migration so pending operations are re-scheduled under the new rules.
4. Must keep: `UUPSUpgradeable`, `_authorizeUpgrade` rules, the upgrade delay floor, timelock + guardian veto, `panic`, recovery, outflow limits, destination allowlist. No `selfdestruct`, no `delegatecall` outside the upgrade path.
5. If the meaning of the signed `Execute` data changes, bump `EIP712_VERSION`.
6. Tests: full suite + an upgrade test from **every** previous release + invariants after upgrade.
7. Independent audit → `proposeRelease` → 7 days → announce.
8. Bytecode budget: `EPKVault` is 22,986 B of the 24,576 B limit. New features should go into validators/modules or external libraries; a release that does not fit must split logic before it can ship.

## 10. Test evidence

`test/v2/EPKVault.upgrade.t.sol` (20 unit/fuzz + 2 invariants):

- upgrade keeps address, funds, settings and runs the migration; `upgradeOperationData` matches;
- timing: needs 2× delay; the 2-day floor holds after lowering the vault delay;
- no direct or generic upgrade path (admin, guardians, attacker, registry, recovery key); migration callable only by the vault, never through `schedule`;
- unapproved / not-yet-active / revoked releases rejected; no downgrade; guardian veto and `panic` stop upgrades; recovery cannot execute admin operations; registry owner cannot upgrade vaults;
- implementation and proxies cannot be re-initialized; factory refuses a revoked implementation; vault accepts 2300-gas `transfer` payments;
- registry: owner-only, version read from code, no lower/equal versions, max one major step, code required, must be a vault, no duplicates, rejects EIP-7702 delegated code, 2-step ownership;
- fuzz: `testFuzz_directUpgradeAlwaysFails` — any caller, any implementation;
- invariants (compromised admin keeps trying, incl. lowering the delay, migrations and generic scheduling; 64 runs × depth 40): `invariant_implementationIsAlwaysAnApprovedRelease`, `invariant_upgradeNeverFasterThanTheFloor`.

## 11. Not done yet

- Independent audit of the vault **and** the upgrade path.
- CI check that diffs the storage layout automatically.
- SDK support (v2 signing format, upgrade helpers) and a guardian monitoring bot that also decodes upgrade operations.
- A safe registry-succession mechanism (today a vault's registry is fixed for life; a new registry means a new vault).
- Recommended registry-owner setup: multisig behind its own timelock.
- ERC-5267 `eip712Domain()` for wallets.
