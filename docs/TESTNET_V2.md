# EPK demo — BSC Testnet

Goal: prove on a real chain that the whole lifecycle of an EPK vault works: an AI agent pays on its own within
its limits, attacks are rejected, a guardian stops everything at once, the owner recovers through the timelock,
and a stolen admin key is stopped by the Watchtower — with the vault address and funds unchanged throughout.
Network: BSC Testnet (chainId 97). Explorer: https://testnet.bscscan.com

Status: **done on 2026-11-08**, on an EPKVault **2.2.0** created through the **public 2.2.0 factory** (SDK
`networks.bscTestnet.epk.factory`). On public test networks the same code runs with minute-scale release clocks
(`contracts/v2/EPKChains.sol`): a new release is usable after a 5-minute public window and a vault upgrades
5 minutes after scheduling (production: 7 days and at least 2 days). The vault's own timelock — here for
unpausing after a panic and for every loosening change — is 1 hour, the minimum on every network. Testnet
only, test token only, **not audited**.

## Roles (testnet keys in the local `.env`, never committed)

| Role | Who |
|---|---|
| Vault admin, treasury | `PRIVATE_KEY` (owner account) |
| Guardians (2); guardian 2 is also the Watchtower's key | `V2_GUARDIAN1_PRIVATE_KEY`, `V2_GUARDIAN2_PRIVATE_KEY` |
| Session manager | `V2_SESSION_MANAGER_PRIVATE_KEY` |
| Recovery key | `V2_RECOVERY_PRIVATE_KEY` |
| AI agent (signs and submits its own batches) | `V2_AGENT_PRIVATE_KEY` |

Vault limits: 1,000 eUSD per day for the whole vault, 100 eUSD per day for each agent session, and the owner's
treasury is the only allowed destination. Timelock delay 1 hour.

## How it was run

Run from the repo root (Foundry loads `.env`; `$BSC_RPC_URL` comes from it).

| # | Command | What it proves |
|---|---|---|
| 1 | `forge script scripts/v2/SetupDemoVault.s.sol:SetupDemoVault --rpc-url $BSC_RPC_URL --broadcast` | a vault created through the public factory and configured; 10,000 eUSD in it |
| 2 | `forge script scripts/v2/DemoSession.s.sol:DemoSession --rpc-url $BSC_RPC_URL --broadcast` | an instant agent session; the agent pays 50 eUSD on its own |
| 3 | `python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2-attacks.json` | 5 attacks rejected on-chain, each with its execution trace saved |
| 4 | `forge script scripts/v2/DemoPanic.s.sol:DemoPanic --sig "panicAndScheduleUnpause()" --rpc-url $BSC_RPC_URL --broadcast` | a guardian stops everything at once; unpausing goes through the timelock |
| 5 | one hour later: `forge script scripts/v2/DemoPanic.s.sol:DemoPanic --sig "recover()" --rpc-url $BSC_RPC_URL --broadcast`, then `python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2-after-panic.json` | service restored with a new session; the pre-panic session stays dead |
| 6 | `python watchtower/epk_watchtower.py --config watchtower/config.bsc-testnet.json` running, then `forge script scripts/v2/DemoStolenKey.s.sol:DemoStolenKey --rpc-url $BSC_RPC_URL --broadcast` and `python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2-stolen-key.json` | a change scheduled with the stolen admin key is cancelled by the Watchtower; executing it anyway is rejected |
| 7 | `python scripts/v2/build_demo_evidence.py` | writes `deployments/bsc-testnet/epk-v2-evidence.json` from the receipts and the vault's state |

## Contracts

| Contract | Address |
|---|---|
| EPKVault 2.2.0 implementation | [0xD5cb4eB76cBABF55769f8c4ebfFb13754b1E5Ffd](https://testnet.bscscan.com/address/0xD5cb4eB76cBABF55769f8c4ebfFb13754b1E5Ffd) |
| EPKRegistry (5-minute test-network release window) | [0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db](https://testnet.bscscan.com/address/0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db) |
| EPKVaultFactory for 2.2.0 — the SDK's public factory | [0xA128110b6C89E3A55E1F7815b75D48fcb124EB48](https://testnet.bscscan.com/address/0xA128110b6C89E3A55E1F7815b75D48fcb124EB48) |
| EPK Demo USD (eUSD) test token | [0x84649B8cb58A572a9DA6F00b24D1Dc6412443d8b](https://testnet.bscscan.com/address/0x84649B8cb58A572a9DA6F00b24D1Dc6412443d8b) |
| Demo vault (customer proxy) | [0x14026E45D119Af294cFb48Ddf7904299641a43fa](https://testnet.bscscan.com/address/0x14026E45D119Af294cFb48Ddf7904299641a43fa) |

Roles of the vault: admin/treasury `0xA2BD166173925E5b8E640f091b0f3bEcBbBE15f8`, guardians `0xcD3951cDfaB38c628a7396812c78C7F3d7C35f70` and `0xD1e73f683515D4A7a26D06AD6b0c64C62d4C7Fa0`,
recovery `0x858CD2931f1b4aFd83b4ef4f2b2cC6EA964AB41C`, session manager `0xbb99385fcf813F59d86d53F454755D48D019f862`, agent `0xcC3b10e3FcBFc15a0B7942B6f06A7c5efB3fde16`.

## Transactions

| Step | What | Tx | Result |
|---|---|---|---|
| 1 | admin creates the demo vault through the public 2.2.0 factory | [0xb85ce98b…](https://testnet.bscscan.com/tx/0xb85ce98b1276112d1b14fbd3403ae8e2f7bcd3806e9adeb0ed4830a21ad80070) | success |
| 2 | setup finalized: 1,000 eUSD/day vault limit, 100 eUSD/day per agent session, only the treasury allowed | [0x97369512…](https://testnet.bscscan.com/tx/0x97369512c169c406a6d7c170a1ab9e4869abb32db11cf679411d01248331195d) | success |
| 3a | session manager opens an AI-agent session (3 days) | [0x10abd710…](https://testnet.bscscan.com/tx/0x10abd7107885d23ef8800d2ad5889821728960e05e66f11f83f6bb98994c85e5) | success |
| 3b | the agent pays 50 eUSD to the treasury on its own | [0x924b580a…](https://testnet.bscscan.com/tx/0x924b580aca19c98e4660df0f5b8722d5f6629ad102349a40ac7c47fd79ad83e9) | success |
| 4a | agent pays 60 eUSD with 50 left in its budget | [0xfe9abf4f…](https://testnet.bscscan.com/tx/0xfe9abf4f640e4a4f82e3f211c65a443e65327a80a84696f3c674ddcf589ee8ea) | **rejected**: `BudgetExceeded` |
| 4b | agent pays to a non-allowlisted address | [0x87f30d89…](https://testnet.bscscan.com/tx/0x87f30d89c27ca220039d3f397f5aa18c0a2ab30712afc131465c2817b4650de5) | **rejected**: `DestinationNotAllowed` |
| 4c | agent calls approve (not in its envelope) | [0x64776437…](https://testnet.bscscan.com/tx/0x6477643746e5cbfaec7de6d5330fc8a00a3a84e426af2d2654317ebefa794417) | **rejected**: `CallNotAllowed` |
| 4d | batch signed by a key that is not the session key | [0x8d2f5df0…](https://testnet.bscscan.com/tx/0x8d2f5df097c0d6330bfac8f1e58223172e6e12fb6e7b0082680500599dcd1601) | **rejected**: `BadSignature` |
| 4e | a stranger submits the agent's valid signature | [0x3efe8652…](https://testnet.bscscan.com/tx/0x3efe8652512bf712bf8971aad8703cc43d86b33a3fa032b2822e32ed044080ac) | **rejected**: `AgentNotAllowed` |
| 5a | a guardian presses panic: everything stops at once | [0x46f714ba…](https://testnet.bscscan.com/tx/0x46f714babe0b665f5d51f8d7fd9946b5daad149ac95ed0bddd0d13c56661d50c) | success |
| 5b | admin schedules unpause through the timelock (1 hour) | [0xb0370b40…](https://testnet.bscscan.com/tx/0xb0370b40b74590e8addba8894ec1d9195bc324190b9a13201de93a3f454035f9) | success |
| 6a | admin executes the timelocked unpause (1 hour after the panic) | [0x113264bd…](https://testnet.bscscan.com/tx/0x113264bd86669e4b01daeb57ac15b1753ab15895fe3e3285d2ace0114decf031) | success |
| 6b | session manager opens a new agent session | [0x6990470c…](https://testnet.bscscan.com/tx/0x6990470c2ac50bdfa9c1eb4ee25896ca5a79e9b05f4cdcfd30ad22da1d41edfa) | success |
| 6c | the agent pays 10 eUSD through the new session | [0x8524fb18…](https://testnet.bscscan.com/tx/0x8524fb183bdde2be47ed9e856c092478367d75fe355a9a13537f4ec75194bd08) | success |
| 6f | the agent tries to pay through the old (pre-panic) session | [0x31f631a4…](https://testnet.bscscan.com/tx/0x31f631a47047f2baf2a9aaf9d9673e893617422ea27d953973f5eb2bf6c9e134) | **rejected**: `PolicyInactive` |
| W1 | attacker with the stolen admin key schedules addDestination(0xBAD1) | [0x0c13847e…](https://testnet.bscscan.com/tx/0x0c13847ef76301c7de2b5cc594c973449b88495ea3aabd70422319436ded6a44) | success |
| W2 | the Watchtower (guardian2 key) cancels it, 4 blocks later | [0x22c88ddb…](https://testnet.bscscan.com/tx/0x22c88ddbab659a89bb9b0e955f54d998e0df692add738f03e7036a4132c559b9) | success |
| W3 | attacker tries to execute the change anyway | [0x8ae785d2…](https://testnet.bscscan.com/tx/0x8ae785d2cdf7b1919e3897d5fb3c0d73734519514bc0ab3e06e1c1ea6c628144) | **rejected**: `UnknownOperation` |

Not a single eUSD left the vault during any attack: 10000 eUSD funded, minus the agent's own 50 and
10 eUSD payments to the treasury = 9940 eUSD. `0xBAD1` never became an allowed destination.

## Check it yourself

No need to trust this page. The same claims are written in machine-readable form in
`deployments/bsc-testnet/epk-v2-evidence.json`, and one command (Python 3 only — no Foundry, no keys, no
packages) checks every one of them against free public BSC Testnet nodes:

```bash
python scripts/v2/verify_evidence.py
git checkout d99008c && forge build && python scripts/v2/verify_evidence.py --build   # bytecode = the code these contracts were deployed from
```

| What | How it is checked |
|---|---|
| Network | `chainId` must be 97 |
| This page = the evidence file | both list exactly the same transactions and contracts |
| Code | every contract has code and its keccak256 hash equals the recorded one; the 2.2.0 implementation must match the hash **pinned in the registry**; the vault's EIP-1967 slot must point to it; with `--build` the implementation, the factory and the vault proxy must equal this repository's compiled bytecode (immutables masked) |
| Who did what | every transaction was sent by the claimed role to the claimed contract |
| Successful steps | the claimed events were emitted by the claimed contract, with the claimed indexed values and amounts (e.g. `Transfer` of exactly 50 eUSD from the vault to the treasury) |
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

Last run 2026-11-08, right after the demo, with the default nodes: **110 checks OK, 0 mismatches, 0 OLD** — all 7
attack reasons STRICT, no eUSD left the vault during any attack (`deployments/bsc-testnet/verification/2026-11-08T1811Z-demo-report.txt`
and the raw node answers `2026-11-08T1811Z-demo-rpc-snapshot.json`). With `--build`: **113 checks OK** — the vault
implementation, the factory and the vault proxy equal this repository's build byte for byte
(`2026-11-08T1812Z-demo-build-report.txt`).

The same checks run in any browser, with no installation: [`docs/proof/index.html`](proof/index.html) ("EPK
Proof of Security") loads the evidence file **from a fixed Git commit** (so the claims it checks cannot be
changed afterwards) and checks it live against the chain.

About the pause: lifting it is never automatic. Only the admin can schedule `unpause`, it waits out the
timelock (1 hour), the admin then executes it, and during the wait the guardians or the recovery key can cancel
it. Another `panic` invalidates it as well.
