# EPK Roadmap

This page is the **single source of truth** for what EPK is today and what comes next.
GitHub (README), DoraHacks and the IBITI Labs website must describe the same state as this page —
no older promises, no features that are not built yet presented as done.

Last updated: 2026-11-07.

## Where we are

| Component | Status |
|---|---|
| **EPK v1** — `EPKernel` + validators | Released (`v1.0.0`, MIT), deployed on BSC testnet. Reference kernel; **not for holding real funds** (shared executor, see `docs/THREAT_MODEL.md`). |
| **EPK v2** — `EPKVault` | In active development on `feature/epk-v2` (draft PR #1), BUSL-1.1. Not audited. **Live on BSC Testnet** since 2026-11-07 with an end-to-end demo anyone can re-check (`docs/TESTNET_V2.md`, `docs/proof/`); not on mainnet. |
| **EPK Watchtower** | Automatic guardian (`watchtower/`, BUSL-1.1). Working on BSC Testnet: cancelled a change scheduled with the stolen admin key 5 blocks after it appeared. |

EPK v2 today:

- **One protected vault per customer** (permanent proxy address); funds and calls come from the customer's own vault.
- **Survives a compromised server / operator key / AI agent**: per-asset outflow limits on real balance changes, destination allowlist, signed batches, allowances that cannot outlive a batch, optional independent co-signer.
- **Agent sessions**: instant, short-lived sessions for AI agents, each with its own budget, only inside envelopes the owner approved through the timelock; one switch stops all sessions of an envelope.
- **Separate roles**: operator, admin, ≥ 2 guardians (can only stop), recovery key, session manager.
- **Tighten instantly, loosen only through a timelock** that guardians can veto; `panic()` stops everything.
- **Upgradeable without moving funds — only by the owner's decision**: registry of reviewed releases (7-day public delay), ≥ 2-day per-vault delay, guardian veto; nobody (including IBITI) can upgrade a vault for its owner. From 2.1 both delays run in parallel (7 days, not 9), and public test networks use 5-minute delays with the same code.
- **Quality**: 120 v2 tests (322 contract tests in the repository including v1, plus 12 Watchtower tests) incl. fuzz and stateful invariants (compromised operator, compromised admin, compromised session manager), four internal security reviews, Slither with every finding fixed or justified.

## Next milestones

| # | Milestone | What it delivers | Status |
|---|---|---|---|
| 1 | **Guard modules** | DEX Guard (swap recipient, token list, deadline and oracle-based slippage checks for V2/V3 routers), ThreatFeed V2 (shared blocklist; blocking instant, unblocking delayed), CompositeGuard — validators that plug into policies without changing the vault; agent sessions get guards with vault release 2.1.0. Design: [`docs/NEXT_STAGE_v2.md`](NEXT_STAGE_v2.md) | **built and tested** on `feature/epk-v2.1` with vault release 2.1.0 (2026-11-07): attack, fuzz, invariant and fork tests ([`docs/GUARDS_v2.md`](GUARDS_v2.md)); **live on BSC Testnet on a separate demo vault** — 11 attacks rejected on-chain, real PancakeSwap + Chainlink ([`docs/TESTNET_V21.md`](TESTNET_V21.md)); not audited |
| 2 | **SDK v2** | TypeScript (viem): create vaults, sign batches and co-signatures, open sessions, schedule changes and upgrades, read limits and budgets | planned |
| 3 | **Watchtower** | Monitoring bot that acts as a guardian: vetoes unexpected scheduled changes, pauses on anomalies, alerts the owner | **working on testnet** (2026-11-07); next: always-on hosting, more alert channels, owner-signed approvals |
| 4 | **Testnet end-to-end** | Public BSC testnet deployment: create vault → deposit → open agent session → allowed payment → blocked attack → upgrade through the timelock → `panic` → recovery, all on the same vault address | **done on testnet** (2026-11-07): steps 1–6 and the Watchtower demo on the 2.0 vault; the opt-in upgrade at the same address was shown on EPK 2.1 in 5 minutes ([`TESTNET_V21_FAST_UPGRADE.md`](TESTNET_V21_FAST_UPGRADE.md)) — the 2.0 → 2.0.1 test planned for 14–16 Nov was cancelled as no longer needed |
| 5 | **Publication** | Merge to `master`, release tag, updated README, DoraHacks page and IBITI Labs website describing exactly this state | by the owner's decision |
| 6 | **Emergency response** | Before any mainnet: (a) instant **evacuation** of a vault's funds to the owner's own cold wallet, registered long in advance (changing it is timelocked) — any protective role may trigger it, nobody can redirect it; (b) a **fast track for critical security fixes** that needs an independent security council's release flag **and** the vault's owner **and** its guardians — never IBITI alone. Design, threat model and attack tests first. `EPKVault` is at the EIP-170 size limit, so new core code means moving logic into modules | planned (before the audit) |
| 7 | **Independent audit** | Professional audit of the vault, sessions and upgrade path; public bug bounty | planned |
| 8 | **Mainnet** | Only after the audit; commercial licenses for production use (BUSL-1.1, see `LICENSING.md`) | after the audit |

Later: ERC-4337 / ERC-7579 smart-account integration, agent identity (ERC-8004), multi-chain deployments, B2B API.

## Rules for every public update

1. GitHub, DoraHacks and the website describe the same version as this page.
2. "Done" means merged, tested and documented; "in development" and "planned" are labelled as such.
3. Nothing is described as audited or production-ready before the independent audit.
