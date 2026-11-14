# EPK demo — opBNB Testnet

Goal: show that EPK is not tied to one network. The same EPK code and the same demo as on BSC Testnet
([`TESTNET_V2.md`](TESTNET_V2.md)), run on **opBNB**, BNB Chain's fast layer 2. An AI agent pays on its own within its
limits; attacks are rejected; a guardian stops everything at once; the owner recovers through the timelock; a stolen
admin key is stopped by the Watchtower; and in an emergency the owner moves everything to the cold wallet registered
in advance, while an attempt to redirect that cold wallet with the stolen key is cancelled.
Network: opBNB Testnet (chainId 5611). Explorer: https://testnet.opbnbscan.com

Status: **done on 2026-11-14**, on a fresh EPK deployment: EPKVault **2.3.0**, a registry that lists it as its
first release, the public factory and the eUSD test token. The only code change for opBNB is one line: opBNB
Testnet joins the public test networks in [`contracts/v2/EPKChains.sol`](../contracts/v2/EPKChains.sol), so the
same minute-scale clocks apply as on BSC Testnet: 5-minute release window, 5-minute upgrade wait, timelock from
5 minutes (production: 7 days, at least 2 days and at least 1 hour). opBNB mainnet keeps the production rules,
like every mainnet (a unit test checks it). This vault's timelock is 5 minutes; a change of the cold wallet waits
three times as long. Testnet only, test token only, **not audited**.

## Roles (testnet keys in the local `.env`, never committed)

The same keys and limits as the BSC Testnet demo:

| Role | Who |
|---|---|
| Vault admin, treasury | `PRIVATE_KEY` (owner account) |
| Guardians (2); guardian 2 is also the Watchtower's key | `V2_GUARDIAN1_PRIVATE_KEY`, `V2_GUARDIAN2_PRIVATE_KEY` |
| Session manager | `V2_SESSION_MANAGER_PRIVATE_KEY` |
| Recovery key (may also evacuate) | `V2_RECOVERY_PRIVATE_KEY` |
| AI agent (signs and submits its own batches) | `V2_AGENT_PRIVATE_KEY` |
| The owner's cold wallet (registered at setup; it only receives) | the address of `V21_INTEGRATOR_PRIVATE_KEY` |

Vault limits: 1,000 eUSD per day for the whole vault, 100 eUSD per day for each agent session, and the owner's
treasury is the only allowed destination. Timelock delay 5 minutes.

## How it was run

Gas money (0.05 tBNB) came from BSC Testnet through BNB Chain's official bridge (`L1StandardBridge`
`0x677311Fd2cCc511Bbc0f581E8d9a07B033D5E840` on BSC Testnet). From the repo root, with `$RPC` =
`https://opbnb-testnet-rpc.bnbchain.org` (Foundry loads `.env`); the scripts write to `deployments/opbnb-testnet/`:

| # | Command | What it proves |
|---|---|---|
| 1 | `forge script scripts/v2/DeployStack.s.sol:DeployStack --rpc-url $RPC --broadcast --slow` | EPKVault 2.3.0 (with its emergency module), the registry, the public factory and the eUSD test token on a new network |
| 2 | `V2_DELAY=300 forge script scripts/v2/SetupDemoVault.s.sol:SetupDemoVault --rpc-url $RPC --broadcast` | a vault created through the public factory and configured, the owner's cold wallet registered; 10,000 eUSD in it |
| 3 | `forge script scripts/v2/DemoSession.s.sol:DemoSession --rpc-url $RPC --broadcast` | an instant agent session; the agent pays 50 eUSD on its own |
| 4 | `python scripts/v2/demo_attacks.py deployments/opbnb-testnet/epk-v2-attacks.json` | 5 attacks rejected on-chain |
| 5 | `forge script scripts/v2/DemoPanic.s.sol:DemoPanic --sig "panicAndScheduleUnpause()" --rpc-url $RPC --broadcast` | a guardian stops everything at once; unpausing goes through the timelock |
| 6 | five minutes later: `forge script scripts/v2/DemoPanic.s.sol:DemoPanic --sig "recover()" --rpc-url $RPC --broadcast`, then `python scripts/v2/demo_attacks.py deployments/opbnb-testnet/epk-v2-after-panic.json` | service restored with a new session; the pre-panic session stays dead |
| 7 | `python watchtower/epk_watchtower.py --config watchtower/config.opbnb-testnet.json` running, then `forge script scripts/v2/DemoStolenKey.s.sol:DemoStolenKey --rpc-url $RPC --broadcast` and `python scripts/v2/demo_attacks.py deployments/opbnb-testnet/epk-v2-stolen-key.json` | a change scheduled with the stolen admin key is cancelled by the Watchtower; executing it anyway is rejected |
| 8 | Watchtower still running: `forge script scripts/v2/DemoEvacuation.s.sol:DemoEvacuation --sig "redirect()" --rpc-url $RPC --broadcast`, then `python scripts/v2/demo_attacks.py deployments/opbnb-testnet/epk-v2-evacuation.json` | the stolen admin key tries to point the cold wallet at itself: the Watchtower cancels it, executing it anyway is rejected, and a guardian cannot evacuate |
| 9 | `forge script scripts/v2/DemoEvacuation.s.sol:DemoEvacuation --sig "evacuate()" --rpc-url $RPC --broadcast` | the recovery key moves everything to the cold wallet registered at setup, and the vault is paused |
| 10 | `python scripts/v2/build_demo_evidence.py --network opbnb-testnet` | writes `deployments/opbnb-testnet/epk-v2-evidence.json` from the receipts and the vault's state |

## Contracts

| Contract | Address |
|---|---|
| EPKVault 2.3.0 implementation | [0x73a79604Bc39b1f6B57Cc68159EE3fc041Ac7Dd9](https://testnet.opbnbscan.com/address/0x73a79604Bc39b1f6B57Cc68159EE3fc041Ac7Dd9) |
| EPKVaultEmergency — the 2.3.0 release's emergency module, deployed by the implementation | [0xF3939aEB10FDa58216d14Cd86de892Bc538Fa9F6](https://testnet.opbnbscan.com/address/0xF3939aEB10FDa58216d14Cd86de892Bc538Fa9F6) |
| EPKRegistry (5-minute test-network release window) | [0x81Ac99466291D2324bf459c7345F5506D9b90158](https://testnet.opbnbscan.com/address/0x81Ac99466291D2324bf459c7345F5506D9b90158) |
| EPKVaultFactory for 2.3.0 — the SDK's public factory | [0x67516e2Bb516D5cAa20408bE622fBAb57d31DEE4](https://testnet.opbnbscan.com/address/0x67516e2Bb516D5cAa20408bE622fBAb57d31DEE4) |
| EPK Demo USD (eUSD) test token | [0xD0F6C69aD004230b4383B72Dc848701e566BeA7C](https://testnet.opbnbscan.com/address/0xD0F6C69aD004230b4383B72Dc848701e566BeA7C) |
| Demo vault (customer proxy) | [0x3CaF011091f0dA6eE432d73678a86957057AFa5b](https://testnet.opbnbscan.com/address/0x3CaF011091f0dA6eE432d73678a86957057AFa5b) |

Roles of the vault: admin/treasury `0xA2BD166173925E5b8E640f091b0f3bEcBbBE15f8`, guardians `0xcD3951cDfaB38c628a7396812c78C7F3d7C35f70` and `0xD1e73f683515D4A7a26D06AD6b0c64C62d4C7Fa0`,
recovery `0x858CD2931f1b4aFd83b4ef4f2b2cC6EA964AB41C`, session manager `0xbb99385fcf813F59d86d53F454755D48D019f862`, agent `0xcC3b10e3FcBFc15a0B7942B6f06A7c5efB3fde16`, the owner's cold
wallet `0x85d4f59F0466eD56D0E7567B3e4ed100e61b3289`.

## Transactions

| Step | What | Tx | Result |
|---|---|---|---|
| 1 | admin creates the demo vault through the public 2.3.0 factory (5-minute timelock, the owner's cold wallet registered) | [0x207f26e9…](https://testnet.opbnbscan.com/tx/0x207f26e92c2c68d989c9de5e10ef52b7d273ae26d768cc1b1cd321bdca3480b3) | success |
| 2 | setup finalized: 1,000 eUSD/day vault limit, 100 eUSD/day per agent session, only the treasury allowed | [0xd1700b20…](https://testnet.opbnbscan.com/tx/0xd1700b202720b04f6e25890beb45dc0be10f52529fe9bf9a642b560e2a84ef4a) | success |
| 3a | session manager opens an AI-agent session (3 days) | [0x414137ed…](https://testnet.opbnbscan.com/tx/0x414137ed74cca7704a1616d03f91820cf4fb7116f4bf4b62fd4e63ea1be0c8f6) | success |
| 3b | the agent pays 50 eUSD to the treasury on its own | [0xf4434f9e…](https://testnet.opbnbscan.com/tx/0xf4434f9e77b909dc243872e741af55c9bce1ffac143f03c6a69688922306cb7c) | success |
| 4a | agent pays 60 eUSD with 50 left in its budget | [0x556fc537…](https://testnet.opbnbscan.com/tx/0x556fc537ddd3abe566c3da3e77b1dbe5720c79c4b777c7be776b01e07a88abae) | **rejected**: `BudgetExceeded` |
| 4b | agent pays to a non-allowlisted address | [0x58c98cf5…](https://testnet.opbnbscan.com/tx/0x58c98cf5fb733d2ce66163fffd5eac6fb95ec2a7c36aac25abe61fe367fa6ba9) | **rejected**: `DestinationNotAllowed` |
| 4c | agent calls approve (not in its envelope) | [0xa0e8426b…](https://testnet.opbnbscan.com/tx/0xa0e8426b152d7d8c06921f5d768b7c15cc8940a06cd8553619b0e5f0697a9996) | **rejected**: `CallNotAllowed` |
| 4d | batch signed by a key that is not the session key | [0x9dcb98ac…](https://testnet.opbnbscan.com/tx/0x9dcb98acfb195681021f1a7e2e8e263d1ccc7d7a702afab7546dfb6fc99050f2) | **rejected**: `BadSignature` |
| 4e | a stranger submits the agent's valid signature | [0x9ebdbed5…](https://testnet.opbnbscan.com/tx/0x9ebdbed58e973dc4e2f39d14b540bf1ac360fa3d264812be9281a62da34c2fa5) | **rejected**: `AgentNotAllowed` |
| 5a | a guardian presses panic: everything stops at once | [0x20494ed4…](https://testnet.opbnbscan.com/tx/0x20494ed45d1d602ca1f87d58aa399fa10c1459ceb3a3e6ec6c1a66f693482017) | success |
| 5b | admin schedules unpause through the timelock (5 minutes on test networks) | [0xd276f1f0…](https://testnet.opbnbscan.com/tx/0xd276f1f04f7aef4450405d70510d58a30db93694d6e46726710311929dbdc8bd) | success |
| 6a | admin executes the timelocked unpause (5 minutes after the panic) | [0xfb24c085…](https://testnet.opbnbscan.com/tx/0xfb24c085d76eaedfdf796aa5a9723de14e23c867d97b47d93e4479d8ded8b547) | success |
| 6b | session manager opens a new agent session | [0xdf8152cb…](https://testnet.opbnbscan.com/tx/0xdf8152cb33c0240b549e5b3503e4b1fce5b3df5423a1e5e40e9b362ab3a6af61) | success |
| 6c | the agent pays 10 eUSD through the new session | [0xd5ce3333…](https://testnet.opbnbscan.com/tx/0xd5ce333362cc1d6a99839d9ff51b5d350e1a92af8ca09aa7c66c46672ae63d0d) | success |
| 6f | the agent tries to pay through the old (pre-panic) session | [0x90f60c12…](https://testnet.opbnbscan.com/tx/0x90f60c12bb8017da00ec2f4db1a3dc2e1e9d3b74869a1d77c35192741719c67f) | **rejected**: `PolicyInactive` |
| W1 | attacker with the stolen admin key schedules addDestination(0xBAD1) | [0xc1a95c92…](https://testnet.opbnbscan.com/tx/0xc1a95c92f5fa7ab9ef405b03d5a57f9713375ece08c63b31ecf8715526a5863d) | success |
| W2 | the Watchtower (guardian2 key) cancels it, 21 blocks later | [0x33f8662b…](https://testnet.opbnbscan.com/tx/0x33f8662bf10de7e7572254a1a9dfab75e1914fc0401ea6552ea0337e4958d145) | success |
| W3 | attacker tries to execute the change anyway | [0xf6a58ec4…](https://testnet.opbnbscan.com/tx/0xf6a58ec4f8cbaa7e047c10afe091cff46ce878af534e20f05950d90fa07135dd) | **rejected**: `UnknownOperation` |
| E1 | attacker with the stolen admin key schedules setColdWallet(0xBAD2) — so that an evacuation would pay them | [0x6bab9361…](https://testnet.opbnbscan.com/tx/0x6bab9361705bff2445550798407614040a74b1eafbf7e6c71aad09a738702c3c) | success |
| E2 | the Watchtower (guardian2 key) cancels it, 25 blocks later | [0x96b1bdf9…](https://testnet.opbnbscan.com/tx/0x96b1bdf98c31bf7ec6e07d1a84da86589d4c01825fa05186f2fa0fb2af37fb42) | success |
| E3 | attacker tries to execute the cold-wallet change anyway | [0xcea80742…](https://testnet.opbnbscan.com/tx/0xcea807426ad738db920636620c96e048c5755bfa3fee08dbab614b3ecb343b5e) | **rejected**: `UnknownOperation` |
| E4 | a guardian tries to evacuate — guardians stop, they never move funds | [0x17047348…](https://testnet.opbnbscan.com/tx/0x17047348d61fb49169633e56b2bec2a50667a64ab2f3ba0403b5ad7a36dc98df) | **rejected**: `NotEvacuator` |
| E5 | the owner's recovery key evacuates everything to the cold wallet registered at setup (and pauses the vault) | [0x3b9b7406…](https://testnet.opbnbscan.com/tx/0x3b9b7406c3256f02813a769edb649ef9ad4017676b8e0a7da1bbb56097bcffde) | success |

Not a single eUSD left the vault during any attack: 10,000 eUSD funded, minus the agent's own 50 and
10 eUSD payments to the treasury = 9,940 eUSD. `0xBAD1` never became an allowed destination. Then the
evacuation moved all 9,940 eUSD to the owner's cold wallet — the one registered at setup; `0xBAD2`
never became the cold wallet — and paused the vault (0 eUSD left in it).

**The Watchtower on opBNB.** opBNB makes a block every 0.25 seconds (BSC Testnet: about 0.45 s), so the same
reaction spans more blocks: the stolen key's change was cancelled 21 blocks, **about 5 seconds**, after it was
mined (W1 → W2), and the cold-wallet redirect 25 blocks, **about 6 seconds**, later (E1 → E2), by the blocks'
own millisecond timestamps. The Watchtower asked the node every 2 seconds and sent each cancel about 3 seconds
after it saw the change; its log of the run: [`deployments/opbnb-testnet/watchtower/2026-11-14-alerts.log`](../deployments/opbnb-testnet/watchtower/2026-11-14-alerts.log).
Each change would only have taken effect 5 minutes (the cold wallet: 15 minutes) after it was scheduled.

## Check it yourself

The same claims are written in machine-readable form in `deployments/opbnb-testnet/epk-v2-evidence.json`, and one
command (Python 3 only — no Foundry, no keys, no packages) checks every one of them against free public opBNB
Testnet nodes:

```bash
python scripts/v2/verify_evidence.py --network opbnb-testnet      # add --build after `git checkout 0b3ca5d && forge build` to compare bytecode with the source it was built from
```

The checks are the same as for BSC Testnet ([`TESTNET_V2.md`](TESTNET_V2.md#check-it-yourself)) with one
difference: **no free opBNB node offers execution traces** (`debug_traceTransaction`), so the reason of every
rejected attack is proven by **REPLAY** — the same transaction replayed against the state right before its block,
plus a check that no earlier transaction in that block touched the vault or the token.

**How long history lasts** (tested 2026-11-14):

| Node | Old transactions and receipts | Old state (checkpoints, replays) | Old event logs |
|---|---|---|---|
| `opbnb-testnet-rpc.bnbchain.org` (BNB Chain's own) | yes (receipts 8 days old still returned) | no (recent blocks only) | yes, 5,000 blocks per request (tested on recent blocks) |
| `5611.rpc.thirdweb.com` | yes | yes (archive) | yes, 1,000 blocks per request |
| `opbnb-testnet.publicnode.com` | yes (receipts 8 days old still returned) | no (recent blocks only) | yes, 5,000 blocks per request (tested on recent blocks) |

Last run 2026-11-14, right after the demo, with the default nodes: **146 checks OK, 0 mismatches, 0 OLD** — all 9
attack reasons proven by REPLAY, no eUSD left the vault during any attack
(`deployments/opbnb-testnet/verification/2026-11-14T2229Z-demo-report.txt` and the raw node answers
`2026-11-14T2229Z-demo-rpc-snapshot.json`). With `--build`: **150 checks OK** — the vault implementation, its emergency
module, the factory and the vault proxy equal this repository's build byte for byte (`2026-11-14T2229Z-demo-build-report.txt`).

The same checks run in any browser, with no installation: [`docs/proof/index.html?net=opbnb`](proof/index.html)
("EPK Proof of Security", switch to opBNB Testnet) loads the evidence file **from a fixed Git commit** and checks it
live against the chain.

Not part of the opBNB demo: the guard modules (protected swaps with PancakeSwap and Chainlink), shown on BSC
Testnet ([`TESTNET_GUARDS.md`](TESTNET_GUARDS.md)), and the opt-in upgrade of an existing vault
([`TESTNET_RELEASE.md`](TESTNET_RELEASE.md)); the code is the same on both networks.
