# EPK v2 — Secure On-Chain Vaults for Autonomous AI Agents

[![CI](https://github.com/VOVAN1980/ibiti-epk-core/actions/workflows/ci.yml/badge.svg)](https://github.com/VOVAN1980/ibiti-epk-core/actions/workflows/ci.yml)
[![Security](https://github.com/VOVAN1980/ibiti-epk-core/actions/workflows/security.yml/badge.svg)](https://github.com/VOVAN1980/ibiti-epk-core/actions/workflows/security.yml)

**Policy-enforced spending limits, isolated agent sessions, emergency controls and owner-controlled upgrades.**

> **Status: EPK 2.1 preview — BSC Testnet only. Not independently audited, not on any mainnet; do not use it
> with real funds.** TypeScript SDK: `npm install @ibiti/epk-sdk@preview viem` ·
> [developer guide](docs/INTEGRATION_v2.md)

EPK (Eternal Permission Kernel) by IBITI Labs gives every customer their own on-chain vault. AI
agents, trading bots and servers pay from it — but only within limits, only to addresses approved
in advance, and only through short-lived sessions. If an agent, the server or the operator key is
compromised, the attacker is still held to those limits and that allowlist and cannot quietly
change the rules: every loosening waits in a timelock that guardians — and the automatic
Watchtower — can cancel. What it does not cover is listed openly [below](#limits).

[Website](https://vovan1980.github.io/ibiti-epk-core/) ·
[Proof of Security](https://vovan1980.github.io/ibiti-epk-core/proof/) ·
[Testnet evidence](docs/TESTNET_V2.md) ·
[Roadmap](docs/ROADMAP.md) ·
[Pilot & licensing](https://vovan1980.github.io/ibiti-epk-core/pilot.html)

---

## Status

| Component | State |
|---|---|
| **EPK v2** — `EPKVault` | **Live on BSC Testnet**: 2.1 since 2026-11-07, release 2.2.0 (the fifth review's fixes) since 2026-11-08 — the public factory creates vaults on 2.2.0 and existing demo vaults opt in ([`docs/TESTNET_V22.md`](docs/TESTNET_V22.md)). Five internal security reviews; **not yet independently audited, not on mainnet**. BUSL-1.1. |
| **Guard modules** — DexGuard, ThreatFeed V2, CompositeGuard | Built and tested; live on a separate BSC Testnet demo vault ([docs/GUARDS_v2.md](docs/GUARDS_v2.md)). BUSL-1.1. |
| **TypeScript SDK** — `@ibiti/epk-sdk` | Preview on npm, testnet only ([docs/INTEGRATION_v2.md](docs/INTEGRATION_v2.md)). MIT. |
| **EPK Watchtower** | Automatic guardian, working on BSC Testnet. BUSL-1.1. |

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
Opt-in upgrades are shown live: a vault upgraded at the same address with the same funds in
5 minutes on BSC Testnet (test networks use minute-scale delays; mainnet keeps 7 days) —
[`docs/TESTNET_V21_FAST_UPGRADE.md`](docs/TESTNET_V21_FAST_UPGRADE.md); the same vault took the real
release 2.2.0 through the SDK on 2026-11-08 ([`docs/TESTNET_V22.md`](docs/TESTNET_V22.md)).

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
| `contracts/v2/` | `EPKVault`, `EPKVaultFactory` (with the proxy), `EPKRegistry`, interfaces; `guards/`: DexGuard, ThreatFeedGuard, CompositeGuard | BUSL-1.1 |
| `test/v2/` | v2 tests: unit, sessions, upgrades, reentrancy, fuzz and stateful invariants | BUSL-1.1 |
| `scripts/v2/` | testnet deployment and demo scripts, evidence verifier, upgrade preflight | BUSL-1.1 |
| `watchtower/` | automatic guardian and its tests | BUSL-1.1 |
| `deployments/bsc-testnet/` | evidence: addresses, transactions, saved traces, verification reports | MIT |
| `docs/` | specifications, security review, roadmap; the website (GitHub Pages) | MIT |
| `sdk/` | TypeScript SDK [`@ibiti/epk-sdk`](https://www.npmjs.com/package/@ibiti/epk-sdk) (bundled guard bytecode: BUSL-1.1) | MIT |

## Build and test

Requirements: [Foundry](https://book.getfoundry.sh/) and Python 3.

```bash
forge build
forge test                                               # 191 contract tests (3 of them fork BSC Testnet and need an RPC)
python -m unittest discover -s watchtower -p "test_*.py" # 15 Watchtower tests, no network
```

Every pull request and every push to `master` runs the tests in [CI](.github/workflows/ci.yml) and
Slither in the [security workflow](.github/workflows/security.yml). Every Slither finding is fixed or
justified in [docs/SLITHER_TRIAGE.md](docs/SLITHER_TRIAGE.md).

## Documentation

- [Specification — EPK v2 (EPKVault)](docs/SPEC_v2.md)
- [Upgrade architecture](docs/EPK_V2_UPGRADE_ARCHITECTURE.md)
- [Internal security review](docs/SECURITY_REVIEW_v2.md) · [Slither triage](docs/SLITHER_TRIAGE.md)
- [Developer guide — integrate EPK v2 with the TypeScript SDK](docs/INTEGRATION_v2.md)
- [BSC Testnet demo and evidence](docs/TESTNET_V2.md) · [guard demo](docs/TESTNET_V21.md) · [5-minute upgrade](docs/TESTNET_V21_FAST_UPGRADE.md)
- [Guard modules](docs/GUARDS_v2.md)
- [Roadmap](docs/ROADMAP.md)

---

## Limits

EPK v2 narrows what a compromised key can do; it does not make loss impossible. In particular:

- Inside its limits, a compromised operator or agent can still spend — up to the configured limit
  per window, and only to allowlisted addresses.
- If the admin key is stolen and no guardian vetoes in time, a timelocked change goes through after
  the delay. Guardians and the Watchtower must run on independent infrastructure.
- Calls other than plain token transfers and approvals are not inspected inside their arguments —
  allowlist swaps, lending or bridges only together with a validator that checks them.

The full list is in the [internal security review, §3](docs/SECURITY_REVIEW_v2.md#3-residual-risks-and-design-limitations).

## Security

EPK v2 has **not** been independently audited yet; do not use it to protect real funds. Please
report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

Configuration lives in `.env` (copy `.env.example`); `.env` is git-ignored — **never commit real keys**.

## License

- **EPK v2** — `contracts/v2/`, `test/v2/`, `scripts/v2/`, `watchtower/`: **Business Source License 1.1**
  ([LICENSE-BUSL-1.1](LICENSE-BUSL-1.1)). Free for study, audits, test networks, hackathons,
  education and research; production use with real assets requires a commercial license. Each
  version becomes MIT no later than 2030-11-06.
- **Everything else** — the SDK code, documentation, the website and the testnet evidence: **MIT** ([LICENSE](LICENSE)).

Details and commercial licensing: [LICENSING.md](LICENSING.md) · info@ibiticoin.com
