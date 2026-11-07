# EPK — Eternal Permission Kernel

[![CI](https://github.com/VOVAN1980/ibiti-epk-core/actions/workflows/ci.yml/badge.svg)](https://github.com/VOVAN1980/ibiti-epk-core/actions/workflows/ci.yml)
[![Security](https://github.com/VOVAN1980/ibiti-epk-core/actions/workflows/security.yml/badge.svg)](https://github.com/VOVAN1980/ibiti-epk-core/actions/workflows/security.yml)

**A vault for AI agents and bots that even a stolen key can't drain.**

EPK v2 gives every customer their own on-chain vault. AI agents, trading bots and servers pay from
it — but only within limits, only to addresses approved in advance, and only through short-lived
sessions. If the server, the operator key or the AI agent is compromised, the attacker still cannot
take more than the limit, cannot send funds anywhere new, and cannot quietly change the rules:
every loosening waits in a timelock that guardians — and the automatic Watchtower — can cancel.

[Website](https://vovan1980.github.io/ibiti-epk-core/) ·
[Proof of Security](https://vovan1980.github.io/ibiti-epk-core/proof/) ·
[Testnet evidence](docs/TESTNET_V2.md) ·
[Roadmap](docs/ROADMAP.md) ·
[Pilot & licensing](https://vovan1980.github.io/ibiti-epk-core/pilot.html)

---

## Status

| Component | State |
|---|---|
| **EPK v2** — `EPKVault` | **Live on BSC Testnet** since 2026-11-07. Four internal security reviews; **not yet independently audited, not on mainnet**. BUSL-1.1. |
| **EPK Watchtower** | Automatic guardian, working on BSC Testnet. BUSL-1.1. |
| **EPK v1** — `EPKernel` | Released `v1.0.0`, frozen, MIT. Reference kernel — **not for holding real funds** ([why](docs/THREAT_MODEL.md)). |

What comes next, and in which order, is in the [roadmap](docs/ROADMAP.md) — the single source of
truth for this README, the website and DoraHacks.

---

## Proven on BSC Testnet

One vault at one address from start to finish
([`0xB2166241…2FA340`](https://testnet.bscscan.com/address/0xB2166241D29C50F4678aebb5061504ee562FA340)),
every step a real transaction:

| What happened | Result |
|---|---|
| The AI agent opens a session and pays the treasury 50 eUSD on its own | ✅ paid |
| 5 attacks: over budget, unknown destination, forbidden call, forged signature, not the agent | ❌ all rejected on-chain |
| A guardian calls `panic()` | everything stops in one transaction |
| Recovery: unpause through the timelock, new agent session | ✅ service restored; the old session stays dead (`PolicyInactive`) |
| A **stolen admin key** schedules a new withdrawal address | 🛡 the Watchtower cancelled it **5 blocks later**; executing it anyway was rejected (`UnknownOperation`) |

**7 of 7** attack transactions rejected · **0 eUSD** left the vault during the attacks.
Next on testnet: the upgrade 2.0.0 → 2.0.1 at the same address through the timelock
(scheduled from 2026-11-14).

### Check it yourself

No need to trust this page. One command — Python 3 only, no Foundry, no keys, no packages —
re-checks every claim in [`deployments/bsc-testnet/epk-v2-evidence.json`](deployments/bsc-testnet/epk-v2-evidence.json)
against a public BSC Testnet node: chain id, bytecode hashes, who sent what, emitted events, revert
reasons, balances and historical checkpoints.

```bash
python scripts/v2/verify_evidence.py
```

The report labels how each fact was proven (**STRICT** execution trace, **REPLAY**, **STATE** or
**EVENTS**) and never marks something as passed when the node can no longer prove it. Details:
[docs/TESTNET_V2.md](docs/TESTNET_V2.md).

---

## How EPK v2 protects the money

- **One isolated vault per customer** (factory, CREATE2, permanent address) — nobody else's policy can reach your funds.
- **Separate roles**: operator signer, admin, ≥ 2 guardians (can only stop, never move funds), recovery key, session manager.
- **Outflow limits per asset**, measured on real balance changes (token bucket).
- **Destination allowlist** for transfers, approvals and native value.
- **Signed batches**; token allowances can never outlive the batch that created them.
- **Optional independent co-signer** for large outflows.
- **Agent sessions**: AI agents get instant, short-lived sessions with their own budgets — only inside envelopes the owner approved through the timelock; one switch stops every session of an envelope.
- **Tighten instantly, loosen only through a timelock** that guardians can veto.
- **`panic()`**: one call pauses the vault and invalidates every policy, session and pending change.
- **Upgrades only by the owner's decision**: registry of reviewed releases (7-day public window), ≥ 2-day per-vault timelock, guardian veto; nobody — including IBITI — can upgrade a vault for its owner ([architecture](docs/EPK_V2_UPGRADE_ARCHITECTURE.md)).

### Watchtower — the automatic guardian

[`watchtower/`](watchtower/README.md) watches the vault's timelock and holds a guardian key. It
knows which changes the owner actually planned; anything else scheduled on the vault is cancelled
automatically, and repeated surprises trigger `panic()`. A guardian can only stop — it can never
move funds.

```bash
python watchtower/epk_watchtower.py --config watchtower/config.bsc-testnet.json --dry-run   # decide only, send nothing
```

---

## Repository layout

| Path | What | License |
|---|---|---|
| `contracts/v2/` | `EPKVault`, `EPKVaultFactory` (with the proxy), `EPKRegistry`, interfaces | BUSL-1.1 |
| `test/v2/` | v2 tests: unit, sessions, upgrades, reentrancy, fuzz and stateful invariants | BUSL-1.1 |
| `scripts/v2/` | testnet deployment and demo scripts, evidence verifier, upgrade preflight | BUSL-1.1 |
| `watchtower/` | automatic guardian and its tests | BUSL-1.1 |
| `deployments/bsc-testnet/` | evidence: addresses, transactions, saved traces, verification reports | MIT |
| `docs/` | specifications, security review, roadmap; the website (GitHub Pages) | MIT |
| `contracts/epk/`, `contracts/validators/`, `contracts/mocks/`, `test/*.sol`, `scripts/` (outside `v2/`) | EPK v1 | MIT |
| `sdk/` | TypeScript SDK for v1 (SDK v2 is on the roadmap) | MIT |

## Build and test

Requirements: [Foundry](https://book.getfoundry.sh/) and Python 3.

```bash
forge build
forge test                                               # 322 contract tests: 120 for v2, 202 for v1
python -m unittest discover -s watchtower -p "test_*.py" # 12 Watchtower tests, no network
```

Every push runs the tests in [CI](.github/workflows/ci.yml); pull requests and `master` also run
Slither in the [security workflow](.github/workflows/security.yml). Every Slither finding is fixed or
justified in [docs/SLITHER_TRIAGE.md](docs/SLITHER_TRIAGE.md).

## Documentation

- [Specification — EPK v2 (EPKVault)](docs/SPEC_v2.md)
- [Upgrade architecture](docs/EPK_V2_UPGRADE_ARCHITECTURE.md)
- [Internal security review](docs/SECURITY_REVIEW_v2.md) · [Slither triage](docs/SLITHER_TRIAGE.md)
- [BSC Testnet demo and evidence](docs/TESTNET_V2.md)
- [Roadmap](docs/ROADMAP.md)
- [Threat model](docs/THREAT_MODEL.md) · [Integration (v1)](docs/INTEGRATION.md) · [Specification — v1](docs/SPEC.md)

---

## EPK v1 (MIT, frozen)

EPK v1 is the original **immutable execution kernel** with capability-based delegation: an owner
creates a policy (allowed agents with TTL, allowed `target + selector` calls, a native value cap,
optional validators), signs an EIP-712 `Execute(policyId, target, value, dataHash, nonce, deadline)`,
and an agent submits it; `setPolicyActive(false)` revokes instantly and `emergencyNonceBump()`
kills queued signatures.

> ⚠️ `EPKernel` is a **shared executor**. Never `approve` tokens to it or send tokens to it —
> see [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md). EPK v2 exists because of this: there every
> customer has their own vault.

- Specification: [docs/SPEC.md](docs/SPEC.md); old website pages: [docs/v1/](docs/v1/)
- BSC Testnet addresses and smoke test: [docs/TESTNET_ADDRESSES_UPDATED.md](docs/TESTNET_ADDRESSES_UPDATED.md)
- Scripts: `scripts/Deploy.s.sol` (kernel + validators), `scripts/SmokeTest.s.sol` (policy → execute → revoke)
- Tests: 202 passing, including invariants (nonce monotonicity, a revoked policy can never execute)

---

## Security

EPK v2 has **not** been independently audited yet; do not use it to protect real funds. Please
report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

Configuration lives in `.env` (copy `.env.example`); `.env` is git-ignored — **never commit real keys**.

## License

- **EPK v2** — `contracts/v2/`, `test/v2/`, `scripts/v2/`, `watchtower/`: **Business Source License 1.1**
  ([LICENSE-BUSL-1.1](LICENSE-BUSL-1.1)). Free for study, audits, test networks, hackathons,
  education and research; production use with real assets requires a commercial license. Each
  version becomes MIT no later than 2030-11-06.
- **Everything else** — EPK v1, the SDK, documentation and the website: **MIT** ([LICENSE](LICENSE)).

Details and commercial licensing: [LICENSING.md](LICENSING.md) · info@ibiticoin.com
