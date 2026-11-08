# EPKVault 2.2.0 on BSC Testnet — the fifth review's fixes, live

Release 2.2.0 closes the two vault findings of the fifth internal review
([SECURITY_REVIEW_v2.md §1e](SECURITY_REVIEW_v2.md), A5-3 and A5-4):

- **A stolen recovery key can no longer freeze a vault.** It cannot veto its own replacement any more; the
  replacement waits 3× the vault's delay and a panic cancels it, so an honest recovery key still beats a
  stolen admin key. Guardians can still veto.
- **Every token approval is checked after the batch**, also `approve(x, 0)` (for an NFT that approves token #0):
  it fails closed. Approvals to address(0) are refused.

It went out on 2026-11-08 exactly the way a release goes out on mainnet — deploy, list in the registry, each
vault opts in through its own timelock — only with the minute-scale clocks of public test networks where the
deployed code has them. Testnet only, test funds only, **not audited**. The 2.0.x demo vault
([`TESTNET_V2.md`](TESTNET_V2.md), 9,940 eUSD) is not touched.

## Contracts

| Contract | Address |
|---|---|
| EPKVault 2.2.0 implementation (24,102 bytes, Shanghai EVM; byte-for-byte this repository's build, immutables masked) | [0xD5cb4eB76cBABF55769f8c4ebfFb13754b1E5Ffd](https://testnet.bscscan.com/address/0xD5cb4eB76cBABF55769f8c4ebfFb13754b1E5Ffd) |
| EPKVaultFactory for 2.2.0 — the SDK's public factory (`networks.bscTestnet.epk.factory`), new vaults start on 2.2.0 | [0xA128110b6C89E3A55E1F7815b75D48fcb124EB48](https://testnet.bscscan.com/address/0xA128110b6C89E3A55E1F7815b75D48fcb124EB48) |
| EPKRegistry of the 5-minute stack (2.2.0 listed after a 5-minute public window) | [0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db](https://testnet.bscscan.com/address/0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db) |
| 5-minute demo vault (proxy, same address since 2.1.0) | [0x9248fb523dE74420b56c733fB9FA14917A054FEb](https://testnet.bscscan.com/address/0x9248fb523dE74420b56c733fB9FA14917A054FEb) |
| A vault an outside integrator would create: SDK quickstart, straight on 2.2.0 | [0xc4158107aCEa510DE0E791315aBdf75eD1f3B65a](https://testnet.bscscan.com/address/0xc4158107aCEa510DE0E791315aBdf75eD1f3B65a) |
| EPKRegistry of the 2.1 guard demo (production 7-day window) | [0x24E861F67180be06A65eF95874404D13FA9631F3](https://testnet.bscscan.com/address/0x24E861F67180be06A65eF95874404D13FA9631F3) |

Code hash of 2.2.0, pinned in both registries: `0xbb4d089a2299025c9118e70a248f16ef97015ae6db9937d2032586db0293be01`.

## What happened (2026-11-08, times UTC from the block)

| Step | Time | Transaction |
|---|---|---|
| EPKVault 2.2.0 deployed | 14:23:41 | [0xe42206fd…](https://testnet.bscscan.com/tx/0xe42206fdf75c82e7663fcd0500d619bd205f7298654ea7e117536797b77309db) |
| Proposed in the 5-minute registry (public window: 5 minutes) | 14:23:43 | [0x3062f73e…](https://testnet.bscscan.com/tx/0x3062f73eaa4e98188541ab51515f4a868238d33b9467d2c2cfa54657a027f013) |
| Proposed in the guard demo's registry (public window: 7 days, until 2026-11-15 14:23 UTC) | 14:23:45 | [0xe6299ab1…](https://testnet.bscscan.com/tx/0xe6299ab176d3c59b8d8a484b25297f92ca4d475dec10762e440df598a1e2733b) |
| SDK v2: the 5-minute vault's admin schedules the upgrade, in parallel with the window | 14:24:03 | [0x3ec16e14…](https://testnet.bscscan.com/tx/0x3ec16e144a8f091a723b027b73bfbeda6fa01c74174a98757afb4c7e99aa431c) |
| SDK v2: upgrade executed — version 2.1.2 → 2.2.0, same address, same 10 tUSD | 14:29:13 | [0xe5ea4703…](https://testnet.bscscan.com/tx/0xe5ea470337820e763f67a088d8303d83db82b960fd80185ae71454c0f9ee2f34) |
| Factory for 2.2.0 deployed | 14:29:45 | [0x3275b6e4…](https://testnet.bscscan.com/tx/0x3275b6e439606e83d693022d064b278931e5f2bcd874ec1731c1fa424ffa6f41) |
| SDK quickstart with a separate integrator key: a new vault created on 2.2.0 through the factory, configured, funded; its bot pays, a "stolen" bot key is refused (`CallNotAllowed`, `LimitExceeded`) before any gas is spent | 14:30:14 | [0xc8be9a0a…](https://testnet.bscscan.com/tx/0xc8be9a0a492a2557ab6eeea195f9a811c53644d6ff928ca84eca0f0942913f74) |

Logs: [`v2.2/2026-11-08-sdk-upgrade-2.2.0.log`](../deployments/bsc-testnet/v2.2/2026-11-08-sdk-upgrade-2.2.0.log)
(the SDK's `EPKUpgrader` and `watchVault`, `sdk/examples/v2-upgrade.ts`) and [`v2.2/2026-11-08-sdk-quickstart-2.2.0.log`](../deployments/bsc-testnet/v2.2/2026-11-08-sdk-quickstart-2.2.0.log) (`sdk/examples/v2-quickstart.ts`). Addresses:
[`deployments/bsc-testnet/epk-v2.2.json`](../deployments/bsc-testnet/epk-v2.2.json).

## Why the 2.1 guard demo vault waits 7 days

The guard demo ([`TESTNET_V21.md`](TESTNET_V21.md)) was deployed on 2026-11-07, a few hours before the
test-network clocks existed (`contracts/v2/EPKChains.sol`). Its registry therefore has the **production**
7-day public window written into its code, and its vault the production upgrade rules (2-day wait, and the
release must already be approved when the upgrade is scheduled). Nobody can shorten that — not the vault's
admin, not IBITI Labs. This is the same protection a mainnet vault has: a new release can be inspected by
everyone for 7 days before any vault can run it.

So 2.2.0 is listed there and becomes usable on 2026-11-15 at 14:23 UTC; the vault then schedules its upgrade
and runs 2.2.0 two days later (`scripts/v2/Release220Testnet.s.sol`: `upgradeGuardDemo()`, then
`executeGuardDemo()`). Until then it runs 2.1.0 with the two known findings — on testnet, with test funds.
Its DexGuard also predates the 2026-11-08 guard fixes; guards are separate contracts and are replaced by
deploying new ones (the SDK's `deployDexGuard` ships the fixed bytecode).

**The guard demo does not wait for it.** During development nothing waits for production clocks: on
2026-11-08 a **new guard demo** started on 2.2.0 — a vault created through the public 2.2.0 factory above
(5-minute clocks), guarded by DexGuard, ThreatFeed V2 and CompositeGuard deployed from the fixed code; 12
attacks rejected on-chain ([`TESTNET_V22_GUARDS.md`](TESTNET_V22_GUARDS.md), live check
`docs/proof/guards.html`). The 2.1 guard demo vault keeps its production clocks, as written into its
contracts, and stays as history with its proofs (`docs/proof/guards-2.1.html`); whether it still opts in on
2026-11-15 changes nothing for the current demo.

## Check it yourself (no keys needed)

```bash
R=https://bsc-testnet-rpc.publicnode.com
cast call 0x9248fb523dE74420b56c733fB9FA14917A054FEb "vaultVersion()(uint64)" --rpc-url $R   # 20200
cast storage 0x9248fb523dE74420b56c733fB9FA14917A054FEb 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $R   # ...d5cb4eb7...5ffd
cast call 0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db "isApproved(address)(bool)" 0xD5cb4eB76cBABF55769f8c4ebfFb13754b1E5Ffd --rpc-url $R   # true
cast call 0xc4158107aCEa510DE0E791315aBdf75eD1f3B65a "vaultVersion()(uint64)" --rpc-url $R   # 20200 (created on 2.2.0)
cast call 0xA128110b6C89E3A55E1F7815b75D48fcb124EB48 "implementation()(address)" --rpc-url $R   # 0xD5cb4eB7…5Ffd
cast call 0x24E861F67180be06A65eF95874404D13FA9631F3 "releases(address)(uint64,uint64,bool,bytes32)" 0xD5cb4eB76cBABF55769f8c4ebfFb13754b1E5Ffd --rpc-url $R   # 20200, usable from 1794752625 (2026-11-15 14:23 UTC)
```

Bytecode against this repository's build (`forge build` first): the on-chain code of the implementation equals
`out/EPKVault.sol/EPKVault.json` `deployedBytecode` with the two UUPS immutables masked, and the factory's equals
`out/EPKVaultFactory.sol/EPKVaultFactory.json` with its two immutables masked (checked 2026-11-08).

## Reproduce

```bash
forge script scripts/v2/Release220Testnet.s.sol:Release220Testnet --sig "start()"  --rpc-url $BSC_RPC_URL --broadcast --slow
cd sdk && npx tsx examples/v2-upgrade.ts && cd ..   # schedules, waits ~5 minutes, executes
forge script scripts/v2/Release220Testnet.s.sol:Release220Testnet --sig "finish()" --rpc-url $BSC_RPC_URL --broadcast --slow
cd sdk && npx tsx examples/v2-quickstart.ts          # any funded testnet key in sdk/.env (ADMIN_PRIVATE_KEY)
```
