# EPKVault 2.4.0 on BSC Testnet and opBNB Testnet — urgent fixes, opt-in upgrade

Release 2.4.0 adds the vault side of the **fast track for urgent security fixes** (design and threat model:
[`FAST_TRACK_v2.md`](FAST_TRACK_v2.md)):

- **A second key for "urgent".** A registry of releases can have a **security council**, a second key held apart
  from the key that proposes releases. The council can flag a proposed **patch** release as an urgent fix, which
  makes it usable at once. Alone it cannot list code, and the proposing key alone cannot flag anything.
- **The owner still decides.** A 2.4.0 vault installs a flagged fix only when its owner schedules it, and then waits
  only its own timelock: on mainnet at least **1 hour** instead of the 2-day upgrade wait; on test networks
  **5 minutes**, as for every upgrade there. Guardians can veto, `panic` cancels it.
- Everything else is 2.3.0: emergency evacuation to the owner's cold wallet, guards, sessions, Watchtower.

It went out on 2026-11-18 on both test networks the way a release goes out on mainnet — deploy, list in the
registry, each vault opts in through its own timelock — only with the minute-scale clocks of public test networks.
Testnet only, test funds only, **not audited**.

## Contracts

The code is the same on both networks. Each implementation deploys its own emergency module, so the addresses
and code hashes differ (the module's address is an immutable in the vault code).

**BSC Testnet** (chainId 97, explorer [testnet.bscscan.com](https://testnet.bscscan.com))

| Contract | Address |
|---|---|
| EPKVault 2.4.0 implementation (24,475 bytes) | [0xB391b1a92AEb6891DbC2f987eb5d117FC62FCc9E](https://testnet.bscscan.com/address/0xB391b1a92AEb6891DbC2f987eb5d117FC62FCc9E) |
| EPKVaultEmergency — 2.4.0's emergency module (3,726 bytes) | [0xc6Eb413ddB07a19b0Bf69882074134873A2f4299](https://testnet.bscscan.com/address/0xc6Eb413ddB07a19b0Bf69882074134873A2f4299) |
| EPKRegistry with a security council — genesis release 2.4.0; the registry of new vaults | [0x56B66a65300b2344c22191FD27a3C3Dccc958dfC](https://testnet.bscscan.com/address/0x56B66a65300b2344c22191FD27a3C3Dccc958dfC) |
| EPKVaultFactory for 2.4.0 — the SDK's public factory (`networks.bscTestnet.epk.factory`) | [0x0d0D4F2590962816Fc9dA07CF55Fa9E645D4DD67](https://testnet.bscscan.com/address/0x0d0D4F2590962816Fc9dA07CF55Fa9E645D4DD67) |
| EPKRegistry the existing vaults use (no council; 2.4.0 listed after its 5-minute window) | [0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db](https://testnet.bscscan.com/address/0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db) |
| 5-minute demo vault: took every release since 2.1.0 at the same address, now 2.4.0, same 10 tUSD | [0x9248fb523dE74420b56c733fB9FA14917A054FEb](https://testnet.bscscan.com/address/0x9248fb523dE74420b56c733fB9FA14917A054FEb) |
| A vault an outside integrator would create: SDK quickstart, straight on 2.4.0 | [0xF11eEa9130db938cEF0753C460283756854ee369](https://testnet.bscscan.com/address/0xF11eEa9130db938cEF0753C460283756854ee369) |

Code hash of 2.4.0 on BSC Testnet: `0xc82618b36d15383b0d3bd892d1ce69912657cca43cac8f29a51d0ab0da13cde0`.

**opBNB Testnet** (chainId 5611, explorer [testnet.opbnbscan.com](https://testnet.opbnbscan.com))

| Contract | Address |
|---|---|
| EPKVault 2.4.0 implementation (24,475 bytes) | [0xc389da518ee4597417E29d1686cE84d057a85FFD](https://testnet.opbnbscan.com/address/0xc389da518ee4597417E29d1686cE84d057a85FFD) |
| EPKVaultEmergency — 2.4.0's emergency module (3,726 bytes) | [0x4f9930Ccac8Ad1af8ba317c13013EE57182A8bFb](https://testnet.opbnbscan.com/address/0x4f9930Ccac8Ad1af8ba317c13013EE57182A8bFb) |
| EPKRegistry with a security council — genesis release 2.4.0; the registry of new vaults | [0x4e7A2d483FBd1f831344ef8472DE0eD680E004E5](https://testnet.opbnbscan.com/address/0x4e7A2d483FBd1f831344ef8472DE0eD680E004E5) |
| EPKVaultFactory for 2.4.0 — the SDK's public factory (`networks.opbnbTestnet.epk.factory`) | [0xF0e8814072101e942Ab0c399305B406c5DCDF418](https://testnet.opbnbscan.com/address/0xF0e8814072101e942Ab0c399305B406c5DCDF418) |
| EPKRegistry the existing vaults use (no council; 2.4.0 listed after its 5-minute window) | [0x81Ac99466291D2324bf459c7345F5506D9b90158](https://testnet.opbnbscan.com/address/0x81Ac99466291D2324bf459c7345F5506D9b90158) |
| Upgrade demo vault: created on 2.3.0 for this release, now 2.4.0, same 10 eUSD | [0xbd2ad182A89a16C8c808F0A3369a3fA488663395](https://testnet.opbnbscan.com/address/0xbd2ad182A89a16C8c808F0A3369a3fA488663395) |

Code hash of 2.4.0 on opBNB Testnet: `0x73e79221adb0062fd617cc8c4a3f541e7a5044476e9d24081127b8bdec9d2055`.

Security council on both networks: the test key `0x714889FEae680E012302679130AE880B010b9560`, separate from the
registry owner. Who holds the council keys on mainnet is not decided yet ([`FAST_TRACK_v2.md`](FAST_TRACK_v2.md)).

## What happened (2026-11-18, times UTC from the block)

**opBNB Testnet**

| Step | Time | Transaction |
|---|---|---|
| Upgrade demo vault created on 2.3.0 through the 2.3.0 factory, setup finalized, 10 eUSD deposited | 21:51:59 – 21:52:05 | [0x2de7afe5…](https://testnet.opbnbscan.com/tx/0x2de7afe5346f28c6b8897e773e6457984595e143d4c47313eafafb718123a60b), [0xb32c9393…](https://testnet.opbnbscan.com/tx/0xb32c939392c89110efaa23f97486dcf8b4d6d2e3aadf01a22b2555b359adf359), [0x42d42312…](https://testnet.opbnbscan.com/tx/0x42d423121b1581c800a1625df13a8bb6130cfa4781e079ee75e131ece2b209d5) |
| EPKVault 2.4.0 deployed (its constructor creates the emergency module) | 21:52:39 | [0x2f88c156…](https://testnet.opbnbscan.com/tx/0x2f88c15642546dbf92677232aabac5f79b064582c59244262fcaa98d9ba91554) |
| Proposed in the existing registry (public window: 5 minutes) | 21:52:41 | [0xbe21f49b…](https://testnet.opbnbscan.com/tx/0xbe21f49bae4ed3d7a4a4bb9967a85f594e41a03d2bad9a1a2901b771a440c470) |
| SDK v2: the vault's admin schedules the upgrade, in parallel with the window | 21:53:08 | [0x1f2c940a…](https://testnet.opbnbscan.com/tx/0x1f2c940afdd3e4eecfffcd2c548d2d101518b51592dcb1c145699cf86d3854ed) |
| SDK v2: upgrade executed — 2.3.0 → 2.4.0, same address, same 10 eUSD | 21:58:14 | [0x412e2cf1…](https://testnet.opbnbscan.com/tx/0x412e2cf1ecf6d313066b536321f2947be71c65796fd9f27dfdf5c4a47a6da8de) |
| Registry with a security council (genesis 2.4.0) | 21:58:54 | [0x7645a71b…](https://testnet.opbnbscan.com/tx/0x7645a71b2aa7a47c5895f022c1a0dfe3532bf818f012a9e9e366549adf31b889) |
| Public factory for 2.4.0 on it | 21:58:55 | [0x0be72b86…](https://testnet.opbnbscan.com/tx/0x0be72b86a5c7ecf22a075acdcb1feb59b2acf8d3224cf53f1c7190d928df611b) |

**BSC Testnet**

| Step | Time | Transaction |
|---|---|---|
| EPKVault 2.4.0 deployed (its constructor creates the emergency module) | 21:53:05 | [0x1d288b7a…](https://testnet.bscscan.com/tx/0x1d288b7aca8f325f0cc30610aad8575dbb09f7a7cda88f5c6bfd6cbd8d10d149) |
| Proposed in the existing registry (public window: 5 minutes) | 21:53:09 | [0x5d00670b…](https://testnet.bscscan.com/tx/0x5d00670ba17df83c9f77592bcab751e51e2a5de3a1450ee92746144f9006afd1) |
| SDK v2: the 5-minute vault's admin schedules the upgrade, in parallel with the window | 21:53:29 | [0x61dc7079…](https://testnet.bscscan.com/tx/0x61dc707907f0491ae80602af085bc80349ec17d65f330e5083c722f7f0595cfe) |
| SDK v2: upgrade executed — 2.3.0 → 2.4.0, same address, same 10 tUSD | 21:58:39 | [0x38594554…](https://testnet.bscscan.com/tx/0x385945544f9628fff722cf567ef768564f6af960f76c45dc478a262eaca88a2f) |
| Registry with a security council (genesis 2.4.0) | 21:59:19 | [0x05e8067b…](https://testnet.bscscan.com/tx/0x05e8067b2aaa06f124765bf901c8aa835da7f980b98717b4d62835c8fd9137eb) |
| Public factory for 2.4.0 on it | 21:59:22 | [0x920a81db…](https://testnet.bscscan.com/tx/0x920a81dbc2e8092a8f6282c864ad22b98bf1594cc850d8b166be28134763dda7) |
| SDK quickstart with a separate integrator key: a new vault on 2.4.0 through the new factory (5-minute timelock), configured, funded; its bot pays, a "stolen" bot key is refused (`CallNotAllowed`, `LimitExceeded`) before any gas is spent | 22:03:23 (payment) | [0xc5deec6d…](https://testnet.bscscan.com/tx/0xc5deec6d69c4668dfa89af8706ef69e5ca08499c62098e0fcc812bd0c71cc428) |

Logs (the SDK's `EPKUpgrader` and `watchVault`, `sdk/examples/v2-upgrade.ts`, and `sdk/examples/v2-quickstart.ts`):

- BSC Testnet: [`release/2026-11-18-sdk-upgrade-2.4.0.log`](../deployments/bsc-testnet/release/2026-11-18-sdk-upgrade-2.4.0.log),
  [`release/2026-11-18-sdk-quickstart-2.4.0.log`](../deployments/bsc-testnet/release/2026-11-18-sdk-quickstart-2.4.0.log);
- opBNB Testnet: [`release/2026-11-18-sdk-upgrade-2.4.0.log`](../deployments/opbnb-testnet/release/2026-11-18-sdk-upgrade-2.4.0.log).

Addresses: [`deployments/bsc-testnet/epk-release.json`](../deployments/bsc-testnet/epk-release.json),
[`deployments/opbnb-testnet/epk-release.json`](../deployments/opbnb-testnet/epk-release.json).

## The security council, live

Read-only checks on both networks right after the release
([BSC Testnet](../deployments/bsc-testnet/release/2026-11-18-release-2.4.0-checks.log),
[opBNB Testnet](../deployments/opbnb-testnet/release/2026-11-18-release-2.4.0-checks.log)):

- the new registry names the council and lists 2.4.0 as its approved genesis release; `isUrgent(2.4.0)` is false;
- `fastTrack` simulated from the **registry owner** and from a **stranger** reverts with `NotCouncil()`: only the
  second key can flag a release as urgent;
- `fastTrack` simulated from the **council** on 2.4.0 reverts with `NotPending`: 2.4.0 is already active, there is
  nothing to rush;
- the registry the existing vaults use has no `council()`: registries from before the fast track have none, and
  their vaults keep the normal path;
- the demo vaults run 2.4.0 at the same address with the same test tokens.

**Not shown live yet: a whole urgent cycle.** It needs a real patch release (2.4.1) to flag; none is made up for a
demo. The first real fix will go through the council on both networks. Until then the whole cycle — flag, the
vault's 1-hour wait on mainnet rules, guardian veto, refusals — runs in `test/v2/EPKRegistry.fastTrack.t.sol`.
On test networks an urgent fix takes about 5 minutes, as any upgrade there.

## Existing vaults and demos

The main demo and the guard demo vaults on both networks stay on 2.3.0, exactly as their evidence records them
([`TESTNET_V2.md`](TESTNET_V2.md), [`TESTNET_GUARDS.md`](TESTNET_GUARDS.md),
[`TESTNET_OPBNB.md`](TESTNET_OPBNB.md), [`TESTNET_OPBNB_GUARDS.md`](TESTNET_OPBNB_GUARDS.md); live checks in
`docs/proof/`). Like any vault, they could opt into 2.4.0; a vault keeps the registry it was created with.

## Check it yourself (no keys needed)

```bash
bash scripts/v2/check_release.sh bsc      # or: opbnb — registry, council, refusals, demo vault, as above
git checkout 0ee45e0 && forge build      # the source these contracts were built from
python scripts/v2/check_release_build.py bsc   # or: opbnb — release, emergency module, registry and factory
                                               # equal this repository's build byte for byte (immutables masked)
```

Reports of these checks on 2026-11-18: `deployments/<network>/verification/2026-11-18T2204Z-release-build-report.txt`.

## Reproduce

```bash
# opBNB Testnet (RPC=https://opbnb-testnet-rpc.bnbchain.org): a small vault on the current release first
forge script scripts/v2/ReleaseTestnet.s.sol:ReleaseTestnet --sig "prepare()" --rpc-url $RPC --broadcast --slow
# both networks (BSC Testnet: RPC=$BSC_RPC_URL)
forge script scripts/v2/ReleaseTestnet.s.sol:ReleaseTestnet --sig "start()"  --rpc-url $RPC --broadcast --slow
cd sdk && npx tsx examples/v2-upgrade.ts [opbnb] && cd ..   # schedules, waits ~5 minutes, executes
EPK_COUNCIL=<council address> forge script scripts/v2/ReleaseTestnet.s.sol:ReleaseTestnet --sig "finish()" --rpc-url $RPC --broadcast --slow
cd sdk && npx tsx examples/v2-quickstart.ts          # any funded BSC Testnet key in ADMIN_PRIVATE_KEY
```

Earlier releases on test networks (2.1.x, 2.2.0, 2.3.0) are listed in [`history/README.md`](../history/README.md).
