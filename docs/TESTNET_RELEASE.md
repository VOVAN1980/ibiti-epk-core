# EPKVault 2.3.0 on BSC Testnet — emergency evacuation to the owner's cold wallet

Release 2.3.0 adds **emergency evacuation** (design and threat model: [`EVACUATION_v2.md`](EVACUATION_v2.md)):

- **One call moves everything to safety.** The admin, the recovery key or an optional evacuator (off by default,
  set through the timelock) moves every tracked asset at once — but only to the **cold wallet the owner
  registered in advance**; nobody chooses the destination in the moment of the emergency. Evacuating also pauses
  the vault and invalidates every pending change, like `panic`.
- **Guardians stop, they never move funds.** A guardian's `evacuate` is refused (`NotEvacuator`).
- **The cold wallet cannot be redirected quietly.** Changing it is scheduled like any loosening change and waits
  three times the vault's delay (on mainnet at least 2 days); guardians, the recovery key and the Watchtower can
  cancel it, and a panic kills it.
- **Minute clocks on test networks.** A vault's own timelock may be as short as 5 minutes on public test
  networks (mainnet: at least 1 hour), next to the 5-minute release window and upgrade wait.

Ordinary payments never need an evacuation: they work as before, through policies, sessions and the timelock.
The emergency code is a separate module, `EPKVaultEmergency` (3,726 bytes), which each implementation deploys in
its own constructor, so the vault stays under the 24,576-byte contract limit (24,390 bytes).

It went out on 2026-11-08 the way a release goes out on mainnet — deploy, list in the registry, each vault opts
in through its own timelock — only with the minute-scale clocks of public test networks. Testnet only, test
funds only, **not audited**; before any mainnet the evacuation must pass an independent security review.

## Contracts

| Contract | Address |
|---|---|
| EPKVault 2.3.0 implementation (24,390 bytes) | [0x214c7a5a9B6b25d559ac714050B66A09E050eA32](https://testnet.bscscan.com/address/0x214c7a5a9B6b25d559ac714050B66A09E050eA32) |
| EPKVaultEmergency — 2.3.0's emergency module, created by the implementation's constructor (3,726 bytes) | [0xFc7eE3221d93E06F781B33fbe9a1a7Bbc074d003](https://testnet.bscscan.com/address/0xFc7eE3221d93E06F781B33fbe9a1a7Bbc074d003) |
| EPKVaultFactory for 2.3.0 — the SDK's public factory (`networks.bscTestnet.epk.factory`), new vaults start on 2.3.0 | [0xbBCeFb781E1A9A21593C4E22a28B6AA2C2bc817B](https://testnet.bscscan.com/address/0xbBCeFb781E1A9A21593C4E22a28B6AA2C2bc817B) |
| EPKRegistry of the 5-minute stack (2.3.0 listed after a 5-minute public window) | [0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db](https://testnet.bscscan.com/address/0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db) |
| 5-minute demo vault (proxy, same address and funds since 2.1.0) | [0x9248fb523dE74420b56c733fB9FA14917A054FEb](https://testnet.bscscan.com/address/0x9248fb523dE74420b56c733fB9FA14917A054FEb) |
| A vault an outside integrator would create: SDK quickstart, straight on 2.3.0 | [0xe91bC5d529f8Faa73c431d912c574653206Bd8e6](https://testnet.bscscan.com/address/0xe91bC5d529f8Faa73c431d912c574653206Bd8e6) |

Code hash of 2.3.0, pinned in the registry: `0x39333931f5618d09a33bbe2e5a4efe5af85a3fe33e6467b670654197db3f1845`.

## What happened (2026-11-08, times UTC from the block)

| Step | Time | Transaction |
|---|---|---|
| EPKVault 2.3.0 deployed (its constructor creates the emergency module) | 21:27:03 | [0xe573bcca…](https://testnet.bscscan.com/tx/0xe573bcca301d792803f2723203bf09dec2ba1f6f09d34318475ef20c7c065d89) |
| Proposed in the 5-minute registry (public window: 5 minutes) | 21:27:06 | [0x2eee87e0…](https://testnet.bscscan.com/tx/0x2eee87e09a3c2be9d7667de95c4152b5484998775c8abf213e3e7b0d376a279a) |
| SDK v2: the 5-minute vault's admin schedules the upgrade, in parallel with the window | 21:27:52 | [0x0a4b36ff…](https://testnet.bscscan.com/tx/0x0a4b36ff116f38eb9e93387e9bb91b576cc58761c52ff657cdcec0821362adcd) |
| SDK v2: upgrade executed — version 2.2.0 → 2.3.0, same address, same 10 tUSD | 21:33:01 | [0xac257e08…](https://testnet.bscscan.com/tx/0xac257e08faa3b895240138aa89b1034f10229415d297038d0765658e484f3df6) |
| Factory for 2.3.0 deployed | 21:33:26 | [0xa314857b…](https://testnet.bscscan.com/tx/0xa314857b90f60c65b51b81bc444e13b3e96e0ccd60c1f39e20c7c2ac4e7ebc8e) |
| SDK quickstart with a separate integrator key: a new vault created on 2.3.0 through the factory (5-minute timelock), configured, funded; its bot pays, a "stolen" bot key is refused (`CallNotAllowed`, `LimitExceeded`) before any gas is spent | 22:02:44 | [0x6d614718…](https://testnet.bscscan.com/tx/0x6d6147187a260ccc8b7f0a4323adf294ab580d8873912a67eba081f5bbeecfff) |

Logs: [`release/2026-11-08-sdk-upgrade-2.3.0.log`](../deployments/bsc-testnet/release/2026-11-08-sdk-upgrade-2.3.0.log)
(the SDK's `EPKUpgrader` and `watchVault`, `sdk/examples/v2-upgrade.ts`) and
[`release/2026-11-08-sdk-quickstart-2.3.0.log`](../deployments/bsc-testnet/release/2026-11-08-sdk-quickstart-2.3.0.log)
(`sdk/examples/v2-quickstart.ts`). Addresses: [`deployments/bsc-testnet/epk-release.json`](../deployments/bsc-testnet/epk-release.json).

A vault that upgrades to 2.3.0 — like the 5-minute vault — starts with no cold wallet: evacuation stays off
until its owner registers one through the timelock. Vaults created on 2.3.0 can register it during setup.

## Demos on 2.3.0

- **Main demo** ([`TESTNET_V2.md`](TESTNET_V2.md), live check `docs/proof/index.html`): a vault created
  through this factory with a 5-minute timelock and a cold wallet registered at setup — agent payments, attacks,
  panic and recovery, a stolen admin key stopped by the Watchtower, and at the end the evacuation under attack:
  the stolen admin key tries to redirect the cold wallet (the Watchtower cancels it, executing it anyway fails),
  a guardian tries to evacuate (refused), then the recovery key moves all 9,940 eUSD to the cold wallet.
- **Guard demo** ([`TESTNET_GUARDS.md`](TESTNET_GUARDS.md), live check `docs/proof/guards.html`): DexGuard,
  ThreatFeed V2 and CompositeGuard on the real PancakeSwap V2 testnet router — 12 attacks rejected on-chain.

## Check it yourself (no keys needed)

```bash
R=https://bsc-testnet-rpc.publicnode.com
cast call 0x9248fb523dE74420b56c733fB9FA14917A054FEb "vaultVersion()(uint64)" --rpc-url $R   # 20300
cast storage 0x9248fb523dE74420b56c733fB9FA14917A054FEb 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $R   # ...214c7a5a...ea32
cast call 0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db "isApproved(address)(bool)" 0x214c7a5a9B6b25d559ac714050B66A09E050eA32 --rpc-url $R   # true
cast call 0xe91bC5d529f8Faa73c431d912c574653206Bd8e6 "vaultVersion()(uint64)" --rpc-url $R   # 20300 (created on 2.3.0)
cast call 0xbBCeFb781E1A9A21593C4E22a28B6AA2C2bc817B "implementation()(address)" --rpc-url $R   # 0x214c7a5a…eA32
```

Bytecode against this repository's build: `git checkout 223e56f && forge build` (the source these contracts were
built from), then `python scripts/v2/verify_evidence.py --build` —
the main demo's evidence lists the implementation, its emergency module, the factory and the vault proxy, and
each must equal this repository's build byte for byte (immutables masked).

## Reproduce

```bash
forge script scripts/v2/ReleaseTestnet.s.sol:ReleaseTestnet --sig "start()"  --rpc-url $BSC_RPC_URL --broadcast --slow
cd sdk && npx tsx examples/v2-upgrade.ts && cd ..   # schedules, waits ~5 minutes, executes
forge script scripts/v2/ReleaseTestnet.s.sol:ReleaseTestnet --sig "finish()" --rpc-url $BSC_RPC_URL --broadcast --slow
cd sdk && npx tsx examples/v2-quickstart.ts          # any funded testnet key in sdk/.env (ADMIN_PRIVATE_KEY)
```
