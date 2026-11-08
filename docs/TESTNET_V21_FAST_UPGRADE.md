# Full vault upgrade on BSC Testnet in 5 minutes (EPK 2.1)

Public test networks use **the same code as mainnet with minute-scale delays** (`contracts/v2/EPKChains.sol`):
a 5-minute release window and a 5-minute upgrade wait, and both run **in parallel**. Mainnets keep the
production rules (7-day release window, 2-day upgrade floor) — and from 2.1 those also run in parallel,
so a new release reaches a vault in 7 days, not 7 + 2. Existing vaults keep the rules of the code they run.

Done on 2026-11-07 on a **separate** vault (the 2.0.x demo vault and the 2.1 guard demo vault are not touched). Testnet only.

| Step | Time (UTC, block time) | Transaction |
|---|---|---|
| Release 2.1.1 proposed in the registry (5-minute public window starts) | 20:26:13 | [0x011e7a9b…](https://testnet.bscscan.com/tx/0x011e7a9b60d8c7b02b5b0e9ef8e0b499539e02dc9e7050cbf99b5240bb5eec7a) |
| The vault's admin schedules the upgrade — in parallel with the window | 20:26:17 | [0xb3c6b6f4…](https://testnet.bscscan.com/tx/0xb3c6b6f494a8b9fa69eb346fb531dcd6ff4529b1fdb4b9c7da385c8091d50e08) |
| Upgrade executed: same address, same 10 tUSD, version 2.1.0 → 2.1.1 | 20:31:36 | [0xa9d8ead1…](https://testnet.bscscan.com/tx/0xa9d8ead146e39f599ee7143bf6197e0ab3ea8d0daabf5c17214be6f26cbdecf7) |

| Contract | Address |
|---|---|
| Vault (proxy, unchanged address) | [0x9248fb523dE74420b56c733fB9FA14917A054FEb](https://testnet.bscscan.com/address/0x9248fb523dE74420b56c733fB9FA14917A054FEb) |
| EPKVault 2.1.0 (genesis) | [0x09BA5c906D8981713b26997F8776c83d1C45FD67](https://testnet.bscscan.com/address/0x09BA5c906D8981713b26997F8776c83d1C45FD67) |
| EPKVault 2.1.1 (demo release) | [0xf4771af722E0380CE241d38E49cD0f8d2EEa90ED](https://testnet.bscscan.com/address/0xf4771af722E0380CE241d38E49cD0f8d2EEa90ED) |
| EPKRegistry | [0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db](https://testnet.bscscan.com/address/0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db) |
| EPKVaultFactory | [0x6f1BAE153931a618878DFe4323e5bE5d9b69B1d6](https://testnet.bscscan.com/address/0x6f1BAE153931a618878DFe4323e5bE5d9b69B1d6) |

### Second upgrade, driven by SDK v2 (2.1.1 → 2.1.2)

The vault's admin used only the TypeScript SDK (`sdk/examples/v2-upgrade.ts`: `EPKUpgrader` schedules, checks
the status and executes; `watchVault` reported the scheduled call decoded as "UPGRADE the vault's code").
Log: `deployments/bsc-testnet/v2.1/2026-11-07-sdk-upgrade.log`.

| Step | Time (UTC) | Transaction |
|---|---|---|
| Release 2.1.2 (a demo release: only its version number changes) proposed ([0x938C220B…](https://testnet.bscscan.com/address/0x938C220B8cec1e6979cbCe53AD51bc9B1E7b3F25)) | 21:14 | [0x9797166f…](https://testnet.bscscan.com/tx/0x9797166f32e80a4a2154ff446e111bfd8e1d4d8bd43be4ae5cf7c8009fad3c84) |
| SDK: upgrade scheduled | 21:14:54 | [0xc687738e…](https://testnet.bscscan.com/tx/0xc687738ee95353b44a5d7690ae1c1a360a36bee99f2949d65a17831551e40573) |
| SDK: upgrade executed — vault now runs 2.1.2, same address | 21:20:02 | [0x7ec2f788…](https://testnet.bscscan.com/tx/0x7ec2f788e709a4f31e4ad82e98d3f2eb9c7ae9cf1e8db2a7d8770fceac421377) |

Check it yourself (no keys needed):

```bash
cast call 0x9248fb523dE74420b56c733fB9FA14917A054FEb "vaultVersion()(uint64)" --rpc-url https://bsc-testnet-rpc.publicnode.com   # 20102 (after both upgrades)
cast call 0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db "approvalDelay()(uint256)" --rpc-url https://bsc-testnet-rpc.publicnode.com # 300 on testnet
```

The same protections hold on test networks, only faster: an unlisted implementation is refused, guardians
can veto a scheduled upgrade, a release revoked during its window never runs (`test/v2/EPKChains.t.sol`).

Reproduce:

```bash
forge script scripts/v2/FastUpgradeDemo.s.sol:FastUpgradeDemo --sig "start()"   --rpc-url $BSC_RPC_URL --broadcast --slow
# 5 minutes later
forge script scripts/v2/FastUpgradeDemo.s.sol:FastUpgradeDemo --sig "execute()" --rpc-url $BSC_RPC_URL --broadcast
```
