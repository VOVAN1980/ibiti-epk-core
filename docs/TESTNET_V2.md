# EPK v2 — BSC Testnet end-to-end demo

Goal: prove on a real chain that the whole EPKVault lifecycle works — with the vault address and
funds unchanged from start to finish. Network: BSC Testnet (chainId 97). Explorer:
https://testnet.bscscan.com

Status: **live on BSC Testnet since 2026-11-07** — steps 1–5 done (deploy, vault, agent payment,
5 attacks rejected on-chain, panic). Steps 6–8 (recovery, upgrade) follow the timelocks. Evidence
(addresses, tx hashes) is in `deployments/bsc-testnet/` and summarised below.

## Roles (testnet keys in the local `.env`, never committed)

| Role | Who |
|---|---|
| Deployer, registry owner, vault admin, treasury | `PRIVATE_KEY` (owner account) |
| Guardians (2) | `V2_GUARDIAN1_PRIVATE_KEY`, `V2_GUARDIAN2_PRIVATE_KEY` |
| Session manager | `V2_SESSION_MANAGER_PRIVATE_KEY` |
| Recovery key | `V2_RECOVERY_PRIVATE_KEY` |
| AI agent (signs and submits its own batches) | `V2_AGENT_PRIVATE_KEY` |

## Steps

Run from the repo root (Foundry loads `.env` automatically; `$BSC_RPC_URL` comes from it).

| # | When | Command | What it proves |
|---|---|---|---|
| 1 | day 0 | `forge script scripts/v2/DeployV2.s.sol:DeployV2 --rpc-url $BSC_RPC_URL --broadcast` | v2 core deployed; demo release 2.0.1 proposed (7-day public window starts) |
| 2 | day 0 | `forge script scripts/v2/SetupDemoVault.s.sol:SetupDemoVault --rpc-url $BSC_RPC_URL --broadcast` | vault created and configured: 1000 eUSD/day vault limit, 100 eUSD/day per agent session, only the treasury allowed |
| 3 | day 0 | `forge script scripts/v2/DemoSession.s.sol:DemoSession --rpc-url $BSC_RPC_URL --broadcast` | instant agent session; the agent pays 50 eUSD on its own |
| 4 | day 0 | `python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2-attacks.json` | 5 attacks rejected on-chain: over budget, unknown destination, forbidden call, forged signature, not the agent |
| 5 | day 0 | `forge script scripts/v2/DemoPanic.s.sol:DemoPanic --sig "panicAndScheduleUnpause()" --rpc-url $BSC_RPC_URL --broadcast` | a guardian stops everything instantly; unpausing goes through the timelock |
| 6 | day 0 + 1 h | `forge script scripts/v2/DemoPanic.s.sol:DemoPanic --sig "recover()" --rpc-url $BSC_RPC_URL --broadcast` then `python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2-after-panic.json` | service restored with a new session; the pre-panic session stays dead |
| 7 | day 7 | `forge script scripts/v2/DemoUpgrade.s.sol:DemoUpgrade --sig "schedule()" --rpc-url $BSC_RPC_URL --broadcast` | the vault opts into the approved 2.0.1 release (timelocked, guardians could veto) |
| 8 | day 9 | `forge script scripts/v2/DemoUpgrade.s.sol:DemoUpgrade --sig "execute()" --rpc-url $BSC_RPC_URL --broadcast` | upgraded to 2.0.1 at the **same address**, funds and settings unchanged |

Cost of the whole demo at current testnet gas prices: about 0.02–0.03 tBNB (including 0.01 tBNB
sent to the role keys for gas).

## Local rehearsal (2026-11-07, fork of BSC Testnet block 141,337,320)

All 8 steps passed, with time travelled forward for steps 6–8:

- agent payment 50 eUSD; session budget left 50; vault limit left 950;
- attacks rejected with `BudgetExceeded`, `DestinationNotAllowed`, `CallNotAllowed`, `BadSignature`, `AgentNotAllowed`;
- after `panic` + timelocked unpause: new session paid 10 eUSD; the old session was rejected with `PolicyInactive`;
- upgrade 2.0.0 → 2.0.1 on the same vault address; vault balance 10,000 − 50 − 10 = 9,940 eUSD.

## Evidence (BSC Testnet, 2026-11-07)

All contracts are verified on BscScan (source code public). Gas for steps 1–5: about 0.0014 tBNB
(plus 0.01 tBNB sent to the role keys).

### Contracts

| Contract | Address |
|---|---|
| EPKVault 2.0.0 — implementation | [0x312455Ed8cAD53B86C21B1aCeD275457cb3F8A1f](https://testnet.bscscan.com/address/0x312455Ed8cAD53B86C21B1aCeD275457cb3F8A1f#code) |
| EPKRegistry | [0x8Eee1F0565241f0C98c8f0cF8754F18E43052b8d](https://testnet.bscscan.com/address/0x8Eee1F0565241f0C98c8f0cF8754F18E43052b8d#code) |
| EPKVaultFactory | [0xa549314e5036912B812BDAE9E938f478eF7A0e48](https://testnet.bscscan.com/address/0xa549314e5036912B812BDAE9E938f478eF7A0e48#code) |
| EPKVault 2.0.1 — demo release (proposed; 7-day window) | [0x6f3AFE980F6f0510581d85907e9a276D5996961b](https://testnet.bscscan.com/address/0x6f3AFE980F6f0510581d85907e9a276D5996961b#code) |
| EPK Demo USD (eUSD) — test token | [0x84649B8cb58A572a9DA6F00b24D1Dc6412443d8b](https://testnet.bscscan.com/address/0x84649B8cb58A572a9DA6F00b24D1Dc6412443d8b#code) |
| **Demo vault** (customer proxy) | [0xB2166241D29C50F4678aebb5061504ee562FA340](https://testnet.bscscan.com/address/0xB2166241D29C50F4678aebb5061504ee562FA340) |

Roles of the demo vault: admin/treasury `0xA2BD166173925E5b8E640f091b0f3bEcBbBE15f8`, guardians
`0xcD3951cDfaB38c628a7396812c78C7F3d7C35f70` and `0xD1e73f683515D4A7a26D06AD6b0c64C62d4C7Fa0`,
recovery `0x858CD2931f1b4aFd83b4ef4f2b2cC6EA964AB41C`, session manager
`0xbb99385fcf813F59d86d53F454755D48D019f862`, agent `0xcC3b10e3FcBFc15a0B7942B6f06A7c5efB3fde16`;
timelock delay 1 hour.

### Transactions

| Step | What | Tx | Result |
|---|---|---|---|
| 1 | registry proposes release 2.0.1 (7-day window starts) | [0xa759a0cf…](https://testnet.bscscan.com/tx/0xa759a0cf4edc51f1e120a10f47d5f09df7231666482551f217342399d3b2e502) | success |
| 2 | factory creates the demo vault | [0x13328f11…](https://testnet.bscscan.com/tx/0x13328f1198ca830fdd9f2323976be85046803099ab42e56a22d8f88453ef2dda) | success |
| 2 | setup finalized (limits, allowlist, envelope; 8 config txs) | [0x574d0759…](https://testnet.bscscan.com/tx/0x574d075987d33742d3ac1ecd11b50bfe594cb821bbb3ac0a5536550ab620b8ee) | success |
| 3 | session manager opens an agent session (3 days) | [0xbee05da3…](https://testnet.bscscan.com/tx/0xbee05da382d51894ad707f6cb45dadb00bc1944d780caac54ed823a99794309d) | success |
| 3 | agent pays 50 eUSD to the treasury on its own | [0x28221368…](https://testnet.bscscan.com/tx/0x28221368b6ac7ea9ef71b6449156fc23259d6b015f56f9f4fa67691c2e9475ae) | success; budget left 50, vault limit left 950 |
| 4a | agent pays 60 eUSD with 50 left in its budget | [0x1f894a80…](https://testnet.bscscan.com/tx/0x1f894a8062d3f67336a3789180f8dacbcf7400d20d1674744ef0ec5fb4c4b78b) | **rejected**: `BudgetExceeded` |
| 4b | agent pays to a non-allowlisted address | [0xba1d5b68…](https://testnet.bscscan.com/tx/0xba1d5b687f29a4128f1393fc53754e9990750a15e0a80a7dea79bf5007a76e12) | **rejected**: `DestinationNotAllowed` |
| 4c | agent calls `approve` (not in its envelope) | [0x806b001f…](https://testnet.bscscan.com/tx/0x806b001fd66db317114bd895f9a5c1a798fc50aa075f8b906c5ab338d645c49e) | **rejected**: `CallNotAllowed` |
| 4d | batch signed by a key that is not the session key | [0xc301be1b…](https://testnet.bscscan.com/tx/0xc301be1bdac7993d932d0ff3ec3363a0193b2764c795d83f2ad39cf06bbb1477) | **rejected**: `BadSignature` |
| 4e | a stranger submits the agent's valid signature | [0x746c76f1…](https://testnet.bscscan.com/tx/0x746c76f1f772785726b0f5b79512b2f84dbb480a8d750ef2b1a2a9adf3834ce3) | **rejected**: `AgentNotAllowed` |
| 5 | guardian presses `panic` | [0xe459a04d…](https://testnet.bscscan.com/tx/0xe459a04d459bf5d12d80c4a4e858673af8f5cd42cb88e77a34aa1f9fbd3d0939) | success; vault paused |
| 5 | admin schedules `unpause` through the timelock (+1 h) | [0x35439ba3…](https://testnet.bscscan.com/tx/0x35439ba3f6c0223682cfd73ddae01c949c63c5f0c4ab7572af757e71635c5b38) | success |

Machine-readable copies: `deployments/bsc-testnet/epk-v2.json`, `epk-v2-vault.json`,
`epk-v2-attacks.json`, `epk-v2-attacks-results.json`.
