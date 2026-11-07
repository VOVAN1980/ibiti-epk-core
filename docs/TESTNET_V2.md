# EPK v2 — BSC Testnet end-to-end demo

Goal: prove on a real chain that the whole EPKVault lifecycle works — with the vault address and
funds unchanged from start to finish. Network: BSC Testnet (chainId 97). Explorer:
https://testnet.bscscan.com

Status: **scripts ready and rehearsed end-to-end on a local fork of BSC Testnet (2026-11-07)**;
real testnet run pending. Evidence (addresses, tx hashes) is written to `deployments/bsc-testnet/`
and summarised below after the run.

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

## Evidence

_Filled in after the real testnet run._
