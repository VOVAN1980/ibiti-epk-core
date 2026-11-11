# History

Earlier BSC Testnet runs of EPK, kept for anyone curious about how the project started. They are not part of
the current product; the current demos and proofs are in [`docs/TESTNET_V2.md`](../docs/TESTNET_V2.md) and
[`docs/TESTNET_GUARDS.md`](../docs/TESTNET_GUARDS.md).

Each run is complete in the git commit named here (documents, evidence, traces, verification reports):

| Run | Date | Commit |
|---|---|---|
| EPK v1.0.0 — the first public release (one shared permission kernel), replaced by v2 | 2026-02-14 | branch [`archive/v1`](https://github.com/VOVAN1980/ibiti-epk-core/tree/archive/v1), tag [`v1.0.0`](https://github.com/VOVAN1980/ibiti-epk-core/tree/v1.0.0) — [`history/v1/`](v1/README.md) |
| First end-to-end demo on EPKVault 2.0.0: agent payment, attacks, panic, recovery, Watchtower | 2026-11-07 | [`bd3cf19`](https://github.com/VOVAN1980/ibiti-epk-core/tree/bd3cf198a361d3bc7780806e9cdd54f2be1a0f59) — `docs/TESTNET_V2.md` |
| First guard demo on EPKVault 2.1.0 (DexGuard, ThreatFeed V2, CompositeGuard) | 2026-11-07 | [`5f0984c`](https://github.com/VOVAN1980/ibiti-epk-core/tree/5f0984c9514d782603ffc55f82a913c70ef7f8d4) — `docs/TESTNET_V21.md` |
| Opt-in upgrade in 5 minutes on test-network clocks (2.1.0 → 2.1.1 → 2.1.2) | 2026-11-07 | [`989e375`](https://github.com/VOVAN1980/ibiti-epk-core/tree/989e375519764d56d57a5ebe863bcce8fc11bea1) — `docs/TESTNET_V21_FAST_UPGRADE.md` |
| Release 2.2.0 (the fifth review's vault fixes), opt-in upgrade through the SDK | 2026-11-08 | [`20b7e94`](https://github.com/VOVAN1980/ibiti-epk-core/tree/20b7e94b22c5dcb8fb958025772d38b485510f80) — `docs/TESTNET_V22.md` |
| Demo on EPKVault 2.2.0: agent payment, attacks, panic, recovery, Watchtower | 2026-11-08 | [`d99008c`](https://github.com/VOVAN1980/ibiti-epk-core/tree/d99008c33c8a44632c2779f832db85e6b5599371) — `docs/TESTNET_V2.md` |
| Guard demo on EPKVault 2.2.0 | 2026-11-08 | [`dfe6d0e`](https://github.com/VOVAN1980/ibiti-epk-core/tree/dfe6d0e0dbf4e803016f76d897e3e776576a33c8) — `docs/TESTNET_V22_GUARDS.md` |

## Archived from `master` on 2026-11-10

Files that belonged to earlier runs or plans and are no longer part of the current product. They are kept in git
history at commit [`3a561b4`](https://github.com/VOVAN1980/ibiti-epk-core/tree/3a561b4ff5b80e3fe68c789521aee93dc9282617):

| What | Where it was |
|---|---|
| 2.1 fast-upgrade demo script and its demo vault releases 2.1.1 / 2.1.2 (the 5-minute upgrade run above) | [`scripts/v2/FastUpgradeDemo.s.sol`](https://github.com/VOVAN1980/ibiti-epk-core/blob/3a561b4ff5b80e3fe68c789521aee93dc9282617/scripts/v2/FastUpgradeDemo.s.sol), [`scripts/v2/demo/EPKVaultDemoRelease211.sol`](https://github.com/VOVAN1980/ibiti-epk-core/blob/3a561b4ff5b80e3fe68c789521aee93dc9282617/scripts/v2/demo/EPKVaultDemoRelease211.sol), [`scripts/v2/demo/EPKVaultDemoRelease212.sol`](https://github.com/VOVAN1980/ibiti-epk-core/blob/3a561b4ff5b80e3fe68c789521aee93dc9282617/scripts/v2/demo/EPKVaultDemoRelease212.sol) |
| Logs of the 2.1 runs: DexGuard fork test, SDK quickstart and SDK upgrade (2026-11-07) | [`deployments/bsc-testnet/v2.1/`](https://github.com/VOVAN1980/ibiti-epk-core/tree/3a561b4ff5b80e3fe68c789521aee93dc9282617/deployments/bsc-testnet/v2.1) |
| Design draft of the guards / SDK / Watchtower stage — built since; the current plan is [`docs/ROADMAP.md`](../docs/ROADMAP.md) | [`docs/NEXT_STAGE_v2.md`](https://github.com/VOVAN1980/ibiti-epk-core/blob/3a561b4ff5b80e3fe68c789521aee93dc9282617/docs/NEXT_STAGE_v2.md) |
