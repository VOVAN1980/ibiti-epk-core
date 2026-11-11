# EPK v2 — Secure On-Chain Vaults for Autonomous AI Agents

<p align="center">
  <img src="docs/img/epk-logo.png" alt="EPK by IBITI Labs" width="180">
</p>

<p align="center"><b>Policy-enforced spending limits, isolated agent sessions, emergency controls and owner-controlled upgrades.</b></p>

<p align="center">
  <a href="https://vovan1980.github.io/ibiti-epk-core/">
    <img src="https://img.shields.io/badge/Live-Proof-0ea5e9?style=for-the-badge" alt="Live proof">
  </a>
  <a href="https://vovan1980.github.io/IBITILabs">
    <img src="https://img.shields.io/badge/IBITI-Labs-purple?style=for-the-badge" alt="IBITI Labs">
  </a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-2.3.0_testnet-informational?style=flat-square" alt="Version">
  <img src="https://img.shields.io/badge/solidity-0.8.24-363636?style=flat-square&logo=solidity" alt="Solidity">
  <img src="https://img.shields.io/badge/network-BSC_Testnet-F0B90B?style=flat-square&logo=bnbchain&logoColor=white" alt="Network">
  <img src="https://img.shields.io/badge/license-IBITI_EPK-orange?style=flat-square" alt="License">
  <a href="https://github.com/VOVAN1980/ibiti-epk-core/actions/workflows/ci.yml"><img src="https://github.com/VOVAN1980/ibiti-epk-core/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/VOVAN1980/ibiti-epk-core/actions/workflows/security.yml"><img src="https://github.com/VOVAN1980/ibiti-epk-core/actions/workflows/security.yml/badge.svg" alt="Security"></a>
</p>

---

> **Status: EPK 2.3.0 — testnet release, BSC Testnet only. Not independently audited, not on any mainnet; do not use it
> with real funds.** TypeScript SDK: [`sdk/`](sdk/) ·
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
| **EPK v2** — `EPKVault` | **Live on BSC Testnet**: release 2.3.0 since 2026-11-08 — emergency evacuation to the owner's cold wallet, minute-scale timelocks on test networks; the public factory creates vaults on 2.3.0 and existing vaults opt in ([`docs/TESTNET_RELEASE.md`](docs/TESTNET_RELEASE.md)). Five internal security reviews; **not yet independently audited, not on mainnet** (the evacuation needs an independent review first). EPK License (source-available). |
| **Guard modules** — DexGuard, ThreatFeed V2, CompositeGuard | Built and tested; live on a separate BSC Testnet demo vault ([docs/GUARDS_v2.md](docs/GUARDS_v2.md)). EPK License. |
| **TypeScript SDK** — `@ibiti/epk-sdk` | In this repository, testnet only; on npm with the finished release ([docs/INTEGRATION_v2.md](docs/INTEGRATION_v2.md)). EPK License. |
| **EPK Watchtower** | Automatic guardian, working on BSC Testnet. EPK License. |

What comes next, and in which order, is in the [roadmap](docs/ROADMAP.md) — the single source of
truth for this README, the website and DoraHacks.

---

## Proven on BSC Testnet

One vault at one address from start to finish
([`0x1538f0Ce…bD4Db`](https://testnet.bscscan.com/address/0x1538f0Cee859c883E12046a6aa52c7CA0f4bD4Db), EPKVault 2.3.0,
5-minute timelock), every step a real transaction:

| What happened | Result |
|---|---|
| The AI agent opens a session and pays the treasury 50 eUSD on its own | ✅ paid |
| 5 attacks: over budget, unknown destination, forbidden call, forged signature, not the agent | ❌ all rejected on-chain |
| A guardian calls `panic()` | everything stops in one transaction |
| Recovery: unpause through the timelock (5 minutes later), new agent session | ✅ service restored; the old session stays dead (`PolicyInactive`) |
| A **stolen admin key** schedules a new withdrawal address | 🛡 the Watchtower cancelled it **9 blocks (about 4 seconds) later**; executing it anyway was rejected (`UnknownOperation`) |
| The stolen admin key tries to **redirect the owner's cold wallet** to itself | 🛡 the Watchtower cancelled it **6 blocks (about 3 seconds) later**; executing it anyway was rejected (`UnknownOperation`) |
| A guardian tries to evacuate the vault | ❌ rejected (`NotEvacuator`) — guardians stop, they never move funds |
| **Emergency evacuation** by the owner's recovery key | ✅ all 9,940 eUSD moved to the cold wallet registered at setup, and the vault paused — in one transaction |

**9 of 9** attack transactions rejected · **0 eUSD** left the vault during the attacks; the only way out in an
emergency was the owner's own cold wallet.
Opt-in upgrades are shown live: a vault took release 2.3.0 through the SDK at the same address with the
same funds, 5 minutes after the release was listed (test networks run 5-minute release and upgrade clocks;
mainnet keeps 7 days + 2 days) — [`docs/TESTNET_RELEASE.md`](docs/TESTNET_RELEASE.md).

### Check it yourself

No need to trust this page. One command — Python 3 only, no Foundry, no keys, no packages —
re-checks every claim in [`deployments/bsc-testnet/epk-v2-evidence.json`](deployments/bsc-testnet/epk-v2-evidence.json)
against free public BSC Testnet nodes (it asks several in turn, because each forgets old history in its
own way): chain id, bytecode hashes, who sent what, emitted events, revert reasons, balances and
historical checkpoints.

```bash
python scripts/v2/verify_evidence.py
```

The report labels how each fact was proven (**STRICT** execution trace, **REPLAY**, **STATE** or
**EVENTS**) and never marks something as passed when no node asked can prove it any more. Details:
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
- **Emergency evacuation**: the admin, the recovery key or an optional evacuator moves every tracked asset at once — only to the cold wallet the owner registered in advance, never anywhere else; changing that wallet waits 3× the timelock (≥ 2 days on mainnet) and guardians can veto it ([design](docs/EVACUATION_v2.md)).
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
| `contracts/v2/` | `EPKVault`, `EPKVaultFactory` (with the proxy), `EPKRegistry`, interfaces; `guards/`: DexGuard, ThreatFeedGuard, CompositeGuard | EPK License |
| `test/v2/` | v2 tests: unit, sessions, upgrades, reentrancy, fuzz and stateful invariants | EPK License |
| `scripts/v2/` | testnet deployment and demo scripts, evidence verifier, upgrade preflight | EPK License |
| `watchtower/` | automatic guardian and its tests | EPK License |
| `deployments/bsc-testnet/` | evidence: addresses, transactions, saved traces, verification reports | EPK License |
| `docs/` | specifications, security review, roadmap; the website (GitHub Pages) | EPK License |
| `sdk/` | TypeScript SDK `@ibiti/epk-sdk` | EPK License |

## Build and test

Requirements: [Foundry](https://book.getfoundry.sh/) and Python 3.

```bash
forge build
forge test                                               # 214 contract tests (3 of them fork BSC Testnet and need an RPC)
python -m unittest discover -s watchtower -p "test_*.py" # 30 Watchtower tests, no network
```

Every pull request and every push to `master` runs the tests in [CI](.github/workflows/ci.yml) and
Slither in the [security workflow](.github/workflows/security.yml). Every Slither finding is fixed or
justified in [docs/SLITHER_TRIAGE.md](docs/SLITHER_TRIAGE.md).

## Documentation

- [Specification — EPK v2 (EPKVault)](docs/SPEC_v2.md)
- [Upgrade architecture](docs/EPK_V2_UPGRADE_ARCHITECTURE.md)
- [Internal security review](docs/SECURITY_REVIEW_v2.md) · [Slither triage](docs/SLITHER_TRIAGE.md)
- [Developer guide — integrate EPK v2 with the TypeScript SDK](docs/INTEGRATION_v2.md)
- [BSC Testnet demo and evidence](docs/TESTNET_V2.md) · [guard demo](docs/TESTNET_GUARDS.md) · [release 2.3.0](docs/TESTNET_RELEASE.md)
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

The whole repository — contracts, tests, scripts, the Watchtower, the SDK, documentation, the website and
the testnet evidence — is under the **IBITI Labs EPK License 1.0** ([LICENSE](LICENSE)); third-party
libraries in `lib/` keep their own licenses. EPK is not open source and does not become open source by itself.

- **Free:** read, study and audit it; run and test it on local chains and public test networks; report
  vulnerabilities; help develop it with issues and pull requests.
- **Only with IBITI Labs (written permission):** hackathons, competitions and grant programmes — nobody
  takes EPK into a competition without us; joint development; anything with real assets or on a main
  network; any commercial use.

Details: [LICENSING.md](LICENSING.md) · info@ibiticoin.com
