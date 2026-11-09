# EPK demo — BSC Testnet

Goal: prove on a real chain that the whole lifecycle of an EPK vault works: an AI agent pays on its own within
its limits, attacks are rejected, a guardian stops everything at once, the owner recovers through the timelock,
a stolen admin key is stopped by the Watchtower, and in an emergency the owner moves everything to the cold
wallet registered in advance — while an attempt to redirect that cold wallet with the stolen key is cancelled.
Network: BSC Testnet (chainId 97). Explorer: https://testnet.bscscan.com

Status: **done on 2026-11-08**, on an EPKVault **2.3.0** created through the **public 2.3.0 factory** (SDK
`networks.bscTestnet.epk.factory`). On public test networks the same code runs with minute-scale clocks
(`contracts/v2/EPKChains.sol`): a new release is usable after a 5-minute public window, a vault upgrades
5 minutes after scheduling, and a vault's own timelock may be as short as 5 minutes (production: 7 days, at
least 2 days and at least 1 hour). This vault's timelock — for unpausing after a panic and for every loosening
change — is 5 minutes; a change of the cold wallet waits three times as long (production: at least 2 days).
Testnet only, test token only, **not audited**.

## Roles (testnet keys in the local `.env`, never committed)

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

Run from the repo root (Foundry loads `.env`; `$BSC_RPC_URL` comes from it).

| # | Command | What it proves |
|---|---|---|
| 1 | `V2_DELAY=300 forge script scripts/v2/SetupDemoVault.s.sol:SetupDemoVault --rpc-url $BSC_RPC_URL --broadcast` | a vault created through the public factory and configured, the owner's cold wallet registered; 10,000 eUSD in it |
| 2 | `forge script scripts/v2/DemoSession.s.sol:DemoSession --rpc-url $BSC_RPC_URL --broadcast` | an instant agent session; the agent pays 50 eUSD on its own |
| 3 | `python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2-attacks.json` | 5 attacks rejected on-chain, each with its execution trace saved |
| 4 | `forge script scripts/v2/DemoPanic.s.sol:DemoPanic --sig "panicAndScheduleUnpause()" --rpc-url $BSC_RPC_URL --broadcast` | a guardian stops everything at once; unpausing goes through the timelock |
| 5 | five minutes later: `forge script scripts/v2/DemoPanic.s.sol:DemoPanic --sig "recover()" --rpc-url $BSC_RPC_URL --broadcast`, then `python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2-after-panic.json` | service restored with a new session; the pre-panic session stays dead |
| 6 | `python watchtower/epk_watchtower.py --config watchtower/config.bsc-testnet.json` running, then `forge script scripts/v2/DemoStolenKey.s.sol:DemoStolenKey --rpc-url $BSC_RPC_URL --broadcast` and `python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2-stolen-key.json` | a change scheduled with the stolen admin key is cancelled by the Watchtower; executing it anyway is rejected |
| 7 | Watchtower still running: `forge script scripts/v2/DemoEvacuation.s.sol:DemoEvacuation --sig "redirect()" --rpc-url $BSC_RPC_URL --broadcast`, then `python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2-evacuation.json` | the stolen admin key tries to point the cold wallet at itself: the Watchtower cancels it, executing it anyway is rejected, and a guardian cannot evacuate |
| 8 | `forge script scripts/v2/DemoEvacuation.s.sol:DemoEvacuation --sig "evacuate()" --rpc-url $BSC_RPC_URL --broadcast` | the recovery key moves everything to the cold wallet registered at setup, and the vault is paused |
| 9 | `python scripts/v2/build_demo_evidence.py` | writes `deployments/bsc-testnet/epk-v2-evidence.json` from the receipts and the vault's state |

## Contracts

| Contract | Address |
|---|---|
| EPKVault 2.3.0 implementation | [0x214c7a5a9B6b25d559ac714050B66A09E050eA32](https://testnet.bscscan.com/address/0x214c7a5a9B6b25d559ac714050B66A09E050eA32) |
| EPKVaultEmergency — the 2.3.0 release's emergency module, deployed by the implementation | [0xFc7eE3221d93E06F781B33fbe9a1a7Bbc074d003](https://testnet.bscscan.com/address/0xFc7eE3221d93E06F781B33fbe9a1a7Bbc074d003) |
| EPKRegistry (5-minute test-network release window) | [0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db](https://testnet.bscscan.com/address/0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db) |
| EPKVaultFactory for 2.3.0 — the SDK's public factory | [0xbBCeFb781E1A9A21593C4E22a28B6AA2C2bc817B](https://testnet.bscscan.com/address/0xbBCeFb781E1A9A21593C4E22a28B6AA2C2bc817B) |
| EPK Demo USD (eUSD) test token | [0x84649B8cb58A572a9DA6F00b24D1Dc6412443d8b](https://testnet.bscscan.com/address/0x84649B8cb58A572a9DA6F00b24D1Dc6412443d8b) |
| Demo vault (customer proxy) | [0x1538f0Cee859c883E12046a6aa52c7CA0f4bD4Db](https://testnet.bscscan.com/address/0x1538f0Cee859c883E12046a6aa52c7CA0f4bD4Db) |

Roles of the vault: admin/treasury `0xA2BD166173925E5b8E640f091b0f3bEcBbBE15f8`, guardians `0xcD3951cDfaB38c628a7396812c78C7F3d7C35f70` and `0xD1e73f683515D4A7a26D06AD6b0c64C62d4C7Fa0`,
recovery `0x858CD2931f1b4aFd83b4ef4f2b2cC6EA964AB41C`, session manager `0xbb99385fcf813F59d86d53F454755D48D019f862`, agent `0xcC3b10e3FcBFc15a0B7942B6f06A7c5efB3fde16`, the owner's cold
wallet `0x85d4f59F0466eD56D0E7567B3e4ed100e61b3289`.

## Transactions

| Step | What | Tx | Result |
|---|---|---|---|
| 1 | admin creates the demo vault through the public 2.3.0 factory (5-minute timelock, the owner's cold wallet registered) | [0x47e31185…](https://testnet.bscscan.com/tx/0x47e31185bf3bb0933a46b85462a29326aa5fca30176a19f0fd71f237148c5b35) | success |
| 2 | setup finalized: 1,000 eUSD/day vault limit, 100 eUSD/day per agent session, only the treasury allowed | [0xd4065ed4…](https://testnet.bscscan.com/tx/0xd4065ed4f664f073d9c2b3d80595b8220c897176fe86699fa453f36327c3ea89) | success |
| 3a | session manager opens an AI-agent session (3 days) | [0x6f619ad7…](https://testnet.bscscan.com/tx/0x6f619ad720d4accd8142a140f4c32d6910a7a1cd97b68dc2cee9c3dac1274462) | success |
| 3b | the agent pays 50 eUSD to the treasury on its own | [0x04b82a2a…](https://testnet.bscscan.com/tx/0x04b82a2a106a4fc015cc80bbff538156535ce76b6e8adddb14c5bd2e1111b1c5) | success |
| 4a | agent pays 60 eUSD with 50 left in its budget | [0x21b49dd4…](https://testnet.bscscan.com/tx/0x21b49dd4bc0e6f091c8f99049784712d15ed1ba5e51996ed922c5e7a292a874b) | **rejected**: `BudgetExceeded` |
| 4b | agent pays to a non-allowlisted address | [0x7c60c421…](https://testnet.bscscan.com/tx/0x7c60c4213d487bf05f8e3cef6151c531c07bad2753a1ec36ecf4a9da685b1962) | **rejected**: `DestinationNotAllowed` |
| 4c | agent calls approve (not in its envelope) | [0x4083a697…](https://testnet.bscscan.com/tx/0x4083a697c43a76c25dbf657a75415d900f015b743a500f70780db5c9caed2fbc) | **rejected**: `CallNotAllowed` |
| 4d | batch signed by a key that is not the session key | [0x752e0f2d…](https://testnet.bscscan.com/tx/0x752e0f2de741737dbd090c20b65099b7de5896cefa98a44a3b3ed7483cd157ea) | **rejected**: `BadSignature` |
| 4e | a stranger submits the agent's valid signature | [0x1d9fab87…](https://testnet.bscscan.com/tx/0x1d9fab8760842ea4e780a10c736f81cd8fd79fb291abab3eeb9ae9593392ae24) | **rejected**: `AgentNotAllowed` |
| 5a | a guardian presses panic: everything stops at once | [0xbd9f067d…](https://testnet.bscscan.com/tx/0xbd9f067d8111ff94342e5a25c5f5068d7c07ebc7f072f6a7eb0babcd15ce0263) | success |
| 5b | admin schedules unpause through the timelock (5 minutes on test networks) | [0x7ee2aa8f…](https://testnet.bscscan.com/tx/0x7ee2aa8f96e3023aa5790e56af67fcb6ab2927d3fca99ed62c7fc9ab2662bf2e) | success |
| 6a | admin executes the timelocked unpause (5 minutes after the panic) | [0xb76dfb92…](https://testnet.bscscan.com/tx/0xb76dfb924bf7fc214cb1f009ba7208d6fb83fa07a77692aae2a6f444450ad9cb) | success |
| 6b | session manager opens a new agent session | [0xc6f71aaf…](https://testnet.bscscan.com/tx/0xc6f71aafcdbfa7b5197f4281b87f755384bb74e59f926ed601cb1c626e796329) | success |
| 6c | the agent pays 10 eUSD through the new session | [0xfe09e9fa…](https://testnet.bscscan.com/tx/0xfe09e9fa1d80e67c3da9f668fc3615eadf8de17d7f68e0a5f73315380a870e65) | success |
| 6f | the agent tries to pay through the old (pre-panic) session | [0x0be10eb0…](https://testnet.bscscan.com/tx/0x0be10eb0a5d54627a00c2e166e43485c1cc5b1e484329f72632fce5f9fc21dcc) | **rejected**: `PolicyInactive` |
| W1 | attacker with the stolen admin key schedules addDestination(0xBAD1) | [0x898a5c22…](https://testnet.bscscan.com/tx/0x898a5c22176a44ddd08ca83050609df076cbe15b10e7e3a0414c3a2a9603cf29) | success |
| W2 | the Watchtower (guardian2 key) cancels it, 9 blocks later | [0xf840e927…](https://testnet.bscscan.com/tx/0xf840e92713ec0609e82298b8ba8df6dbd938df88268a585c1c959318e26762c0) | success |
| W3 | attacker tries to execute the change anyway | [0x546714e9…](https://testnet.bscscan.com/tx/0x546714e9af91412eaca6336e769a5a49cc6eac9d39d2ab5e5e7932360de9e550) | **rejected**: `UnknownOperation` |
| E1 | attacker with the stolen admin key schedules setColdWallet(0xBAD2) — so that an evacuation would pay them | [0x4ed25a8a…](https://testnet.bscscan.com/tx/0x4ed25a8ac08934553869fd13710baf836a929a4ce3e3744d01ad181a79485942) | success |
| E2 | the Watchtower (guardian2 key) cancels it, 6 blocks later | [0x6a53e86e…](https://testnet.bscscan.com/tx/0x6a53e86e0e4278b8ccf87ecaf6c92043273a35ec6cf1f3bd8cada37a91756b4c) | success |
| E3 | attacker tries to execute the cold-wallet change anyway | [0x566d08e0…](https://testnet.bscscan.com/tx/0x566d08e0cc3cbe3cb9cb679e362f45300c60add2e1ff38d82bc1c1f20868cb35) | **rejected**: `UnknownOperation` |
| E4 | a guardian tries to evacuate — guardians stop, they never move funds | [0x68da8273…](https://testnet.bscscan.com/tx/0x68da8273c51b92a1ae0d61722a4bf5a3508e16ee034b8202a4badbe5fc36b244) | **rejected**: `NotEvacuator` |
| E5 | the owner's recovery key evacuates everything to the cold wallet registered at setup (and pauses the vault) | [0xa36d6be2…](https://testnet.bscscan.com/tx/0xa36d6be26185ed11fe75ac4c83ee99741faa82956663f25a5946b0169a9da3ba) | success |

Not a single eUSD left the vault during any attack: 10,000 eUSD funded, minus the agent's own 50 and
10 eUSD payments to the treasury = 9,940 eUSD. `0xBAD1` never became an allowed destination. Then the
evacuation moved all 9,940 eUSD to the owner's cold wallet — the one registered at setup; `0xBAD2`
never became the cold wallet — and paused the vault (0 eUSD left in it).

## Check it yourself

No need to trust this page. The same claims are written in machine-readable form in
`deployments/bsc-testnet/epk-v2-evidence.json`, and one command (Python 3 only — no Foundry, no keys, no
packages) checks every one of them against free public BSC Testnet nodes:

```bash
python scripts/v2/verify_evidence.py            # add --build after `git checkout 223e56f && forge build` to compare bytecode with the source it was built from
```

| What | How it is checked |
|---|---|
| Network | `chainId` must be 97 |
| This page = the evidence file | both list exactly the same transactions and contracts |
| Code | every contract has code and its keccak256 hash equals the recorded one; the implementation must match the hash **pinned in the registry**; the vault's EIP-1967 slot must point to it; with `--build` the implementation, its emergency module, the factory and the vault proxy must equal this repository's compiled bytecode (immutables masked) |
| Who did what | every transaction was sent by the claimed role to the claimed contract |
| Successful steps | the claimed events were emitted by the claimed contract, with the claimed indexed values and amounts (e.g. `Transfer` of exactly 50 eUSD from the vault to the treasury, or of all 9,940 eUSD to the cold wallet) |
| Rejected steps | failed by revert, not by running out of gas, and the claimed custom error is proven — **STRICT**: read from the execution trace of that exact transaction, saved in `deployments/bsc-testnet/traces/` right after sending (its sender, target and input must match the transaction); **REPLAY** when no trace exists: the same transaction replayed against the state right before its block |
| Money | for each attack window, the vault balance before the first attack equals the balance after the last one |
| History | fixed block-number checkpoints (paused, implementation, balance, limits left). **STATE** = read from a node's historical state; when no node asked keeps it, **EVENTS** = derived from event logs of one node whose logs contain every event of the evidence transactions. A value that cannot be checked any more is reported as **OLD** — never as passed |

**How long history lasts.** Every free public node forgets old history, each in its own way (tested
2026-11-08):

| Node | Old transactions and receipts | Old state (checkpoints, replays) | Old event logs |
|---|---|---|---|
| `bsc-testnet.bnbchain.org` (BNB Chain's own) | yes | no (latest blocks only) | refused ("limit exceeded") |
| `97.rpc.thirdweb.com` | yes | yes (archive) | yes, 1,000 blocks per request; strict rate limit |
| `bsc-testnet-rpc.publicnode.com` | about the last day only | about the last hour | silently empty for old blocks |

So the script (and the proof pages) ask several nodes, in this order: every request goes to the first node, and
the next one is asked only when a node has no answer — a transaction it no longer returns, state it has pruned,
a request it refuses, or no response; a revert is an answer and is never retried elsewhere. `--rpc-url A,B`
replaces the list (one URL = only that node). Exit code 0 = everything checkable matches (details no node asked
still keeps are listed as OLD), 1 = a mismatch, 2 = something could not be checked.

Last run 2026-11-08, right after the demo, with the default nodes: **137 checks OK, 0 mismatches, 0 OLD** — all 9
attack reasons STRICT, no eUSD left the vault during any attack (`deployments/bsc-testnet/verification/2026-11-08T2150Z-demo-report.txt`
and the raw node answers `2026-11-08T2150Z-demo-rpc-snapshot.json`). With `--build`: **141 checks OK** — the vault
implementation, its emergency module, the factory and the vault proxy equal this repository's build byte for byte
(`2026-11-08T2152Z-demo-build-report.txt`).

The same checks run in any browser, with no installation: [`docs/proof/index.html`](proof/index.html) ("EPK
Proof of Security") loads the evidence file **from a fixed Git commit** (so the claims it checks cannot be
changed afterwards) and checks it live against the chain.

About the pause: lifting it is never automatic. Only the admin can schedule `unpause`, it waits out the
timelock (5 minutes here), the admin then executes it, and during the wait the guardians or the recovery key can
cancel it. Another `panic` invalidates it as well.

About the evacuation (design: [`EVACUATION_v2.md`](EVACUATION_v2.md)): the admin, the recovery key or an
optional evacuator (off by default, set through the timelock) can move every tracked asset at once — but only
to the cold wallet the owner registered in advance; nobody chooses the destination at the moment of the
emergency. Evacuating also pauses the vault and invalidates every pending change, like `panic`. Guardians stop,
but never move funds. Changing the cold wallet is scheduled like any loosening change and waits three times the
vault's delay (on mainnet at least 2 days), so the guardians or the Watchtower can cancel it. Ordinary
payments never need an evacuation.
