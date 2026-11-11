# EPK Roadmap

This page is the **single source of truth** for what EPK is today and what comes next.
GitHub (README), DoraHacks and the IBITI Labs website must describe the same state as this page —
no older promises, no features that are not built yet presented as done.

Last updated: 2026-11-08.

## Where we are

| Component | Status |
|---|---|
| **EPK v2** — `EPKVault` | The main version of this repository: 2.3 preview (release 2.3.0 on BSC Testnet since 2026-11-08: emergency evacuation to the owner's cold wallet, and a 5-minute minimum timelock on test networks, so nothing in testnet development waits an hour), EPK License (source-available), TypeScript SDK in `sdk/` (published on npm with the finished release). Not audited. **Live on BSC Testnet** with an end-to-end demo on 2.3.0 anyone can re-check (`docs/TESTNET_V2.md`, `docs/proof/`); not on mainnet. |
| **EPK Watchtower** | Automatic guardian (`watchtower/`, EPK License). Working on BSC Testnet: cancelled a change scheduled with the stolen admin key 9 blocks (about 4 seconds) after it appeared, and an attempt to redirect the owner's cold wallet 6 blocks (about 3 seconds) after it appeared. |

EPK v2 today:

- **One protected vault per customer** (permanent proxy address); funds and calls come from the customer's own vault.
- **Survives a compromised server / operator key / AI agent**: per-asset outflow limits on real balance changes, destination allowlist, signed batches, allowances that cannot outlive a batch, optional independent co-signer.
- **Agent sessions**: instant, short-lived sessions for AI agents, each with its own budget, only inside envelopes the owner approved through the timelock; one switch stops all sessions of an envelope.
- **Separate roles**: operator, admin, ≥ 2 guardians (can only stop), recovery key, session manager.
- **Tighten instantly, loosen only through a timelock** that guardians can veto; `panic()` stops everything.
- **Upgradeable without moving funds — only by the owner's decision**: registry of reviewed releases (7-day public delay), ≥ 2-day per-vault delay, guardian veto; nobody (including IBITI) can upgrade a vault for its owner. From 2.1 both delays run in parallel (7 days, not 9), and public test networks use 5-minute delays with the same code.
- **Quality**: 214 contract tests (plus 24 Watchtower and 16 SDK tests) incl. fuzz and stateful invariants (compromised operator, compromised admin, compromised session manager), five internal security reviews (the fifth, 2026-11-08, attacked guards, Watchtower, SDK and website too — [SECURITY_REVIEW_v2.md §1e](SECURITY_REVIEW_v2.md)), Slither with every finding fixed or justified.

## Next milestones

| # | Milestone | What it delivers | Status |
|---|---|---|---|
| 1 | **Guard modules** | DEX Guard (swap recipient, token list, deadline and oracle-based slippage checks for V2/V3 routers), ThreatFeed V2 (shared blocklist; blocking instant, unblocking delayed), CompositeGuard — validators that plug into policies without changing the vault; agent sessions get guards with vault release 2.1.0. Design (archived): [`NEXT_STAGE_v2.md`](https://github.com/VOVAN1980/ibiti-epk-core/blob/3a561b4ff5b80e3fe68c789521aee93dc9282617/docs/NEXT_STAGE_v2.md) | **built and tested** with vault release 2.1.0 (2026-11-07): attack, fuzz, invariant and fork tests ([`docs/GUARDS_v2.md`](GUARDS_v2.md)); **live on BSC Testnet on a separate demo vault** on vault release 2.2.0 — 12 attacks rejected on-chain, real PancakeSwap + Chainlink ([`docs/TESTNET_GUARDS.md`](TESTNET_GUARDS.md)); not audited |
| 2 | **SDK v2** | TypeScript (viem): create vaults, sign batches and co-signatures, open sessions, schedule changes and upgrades, read limits and budgets | **built (preview)**: `@ibiti/epk-sdk` 2.0.0-preview.1 — vaults, batches, sessions, timelock, upgrades, guards, events ([INTEGRATION_v2.md](INTEGRATION_v2.md)); co-signature helper not yet |
| 3 | **Watchtower** | Monitoring bot that acts as a guardian: vetoes unexpected scheduled changes, pauses on anomalies, alerts the owner | **working on testnet** (cancelled a stolen-key change 9 blocks, about 4 seconds, after it was scheduled, and a stolen-key redirect of the owner's cold wallet 6 blocks later); alerts to Telegram and a signed webhook with a daily heartbeat (2026-11-11), never delaying a cancel; next: always-on 24/7 hosting, e-mail / Discord / Slack alerts, owner-signed approvals |
| 4 | **Testnet end-to-end** | Public BSC testnet deployment: create vault → deposit → open agent session → allowed payment → blocked attack → upgrade through the timelock → `panic` → recovery, all on the same vault address | **done on testnet** on vault release 2.3.0: payment, attacks, panic, recovery, the Watchtower and the emergency evacuation on one vault ([`TESTNET_V2.md`](TESTNET_V2.md)); the opt-in upgrade at the same address through the SDK in 5 minutes ([`TESTNET_RELEASE.md`](TESTNET_RELEASE.md)) |
| 5 | **Publication** | Merge to `master`, release tag, updated README, DoraHacks page and IBITI Labs website describing exactly this state | **EPK 2.3.0 — Testnet** released on GitHub (2026-11-09) with the IBITI Labs EPK License; websites updated; DoraHacks page updated by the owner |
| 6 | **Emergency response** | Before any mainnet: (a) instant **evacuation** of a vault's funds to the owner's own cold wallet, registered long in advance (changing it is timelocked) — any protective role may trigger it, nobody can redirect it; (b) a **fast track for critical security fixes** that needs an independent security council's release flag **and** the vault's owner **and** its guardians — never IBITI alone. Design, threat model and attack tests first; (a) is drafted in [`EVACUATION_v2.md`](EVACUATION_v2.md). `EPKVault` is at the EIP-170 size limit, so new core code means moving logic into modules | (a) **on BSC Testnet since 2026-11-08** (release 2.3.0): attack tests, then the main demo evacuated under attack ([`TESTNET_V2.md`](TESTNET_V2.md) steps E1–E5); an independent security review before any mainnet. (b) planned (before the audit) |
| 7 | **Independent audit** | Professional audit of the vault, sessions and upgrade path; public bug bounty | planned |
| 8 | **Mainnet** | Only after the audit; commercial licenses for production use (EPK License, see `LICENSING.md`) | after the audit |

Later: ERC-4337 / ERC-7579 smart-account integration, agent identity (ERC-8004), multi-chain deployments, B2B API.

## Rules for every public update

1. GitHub, DoraHacks and the website describe the same version as this page.
2. "Done" means merged, tested and documented; "in development" and "planned" are labelled as such.
3. Nothing is described as audited or production-ready before the independent audit.
