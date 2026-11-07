# EPK v2 — BSC Testnet end-to-end demo

Goal: prove on a real chain that the whole EPKVault lifecycle works — with the vault address and
funds unchanged from start to finish. Network: BSC Testnet (chainId 97). Explorer:
https://testnet.bscscan.com

Status: **live on BSC Testnet since 2026-11-07** — steps 1–6 done (deploy, vault, agent payment,
5 attacks rejected on-chain, panic, recovery with a new session; the pre-panic session stays
dead), plus the **Watchtower demo** (W1–W3: a change scheduled with the stolen admin key was
cancelled automatically 5 blocks later; see [`watchtower/README.md`](../watchtower/README.md)).
Steps 7–8 (upgrade to 2.0.1) follow the 7-day release window: schedule from 2026-11-14,
execute 2 days later. Evidence (addresses, tx hashes) is in `deployments/bsc-testnet/` and
summarised below.

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
| 7 | day 7 (from 2026-11-14 12:04:02 UTC by block time) | `python scripts/v2/upgrade_preflight.py schedule` → only if READY and the owner confirms: `forge script scripts/v2/DemoUpgrade.s.sol:DemoUpgrade --sig "schedule()" --rpc-url $BSC_RPC_URL --broadcast` | the vault opts into the approved 2.0.1 release (timelocked, guardians could veto); preflight saves a snapshot of all 29 public vault settings |
| 8 | day 9 (2 days after step 7, by block time) | `python scripts/v2/upgrade_preflight.py execute` → only if READY and the owner confirms: `forge script scripts/v2/DemoUpgrade.s.sol:DemoUpgrade --sig "execute()" --rpc-url $BSC_RPC_URL --broadcast` → `python scripts/v2/upgrade_preflight.py after` | upgraded to 2.0.1 at the **same address**; all 29 settings, both balances and the vault's own code byte-for-byte unchanged |

`upgrade_preflight.py` signs nothing. It decides only by block timestamps, checks the registry
approval, the release's code hash (= registry pin = evidence file), the vault state, a dry run of the
exact call, and, for `execute`/`after`, that no vault setting changed. Signing stays a separate, manual
step after the owner's confirmation. Rehearsed in full on a local fork of BSC Testnet on 2026-11-07
(time moved to 14 and 16 November): READY on day 7, refused one day later with `OperationNotReady()`,
READY on day 9, then `UPGRADE VERIFIED` — same address, version 20001, 29/29 settings and 9,940 eUSD
unchanged.

Cost of the whole demo at current testnet gas prices: about 0.02–0.03 tBNB (including 0.01 tBNB
sent to the role keys for gas).

## Local rehearsal (2026-11-07, fork of BSC Testnet block 141,337,320)

All 8 steps passed, with time travelled forward for steps 6–8:

- agent payment 50 eUSD; session budget left 50; vault limit left 950;
- attacks rejected with `BudgetExceeded`, `DestinationNotAllowed`, `CallNotAllowed`, `BadSignature`, `AgentNotAllowed`;
- after `panic` + timelocked unpause: new session paid 10 eUSD; the old session was rejected with `PolicyInactive`;
- upgrade 2.0.0 → 2.0.1 on the same vault address; vault balance 10,000 − 50 − 10 = 9,940 eUSD.

## Evidence (BSC Testnet, 2026-11-07)

All contracts are verified on BscScan (source code public). Gas for steps 1–6: about 0.0014 tBNB
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
| 6 | admin executes the timelocked `unpause` (1 h after panic) | [0x9979f260…](https://testnet.bscscan.com/tx/0x9979f260dbb2fab88f7cca90835fbadd110972dae7190a6f49daa26b7ed636a0) | success; vault unpaused |
| 6 | session manager opens a **new** agent session | [0x24f9fdd1…](https://testnet.bscscan.com/tx/0x24f9fdd1c32850ea4dabc20a1f7b17879ee57071367e970f71cc30f19c19a955) | success |
| 6 | agent pays 10 eUSD through the new session | [0xf6230b91…](https://testnet.bscscan.com/tx/0xf6230b91efc20c1e03ff92a22109896671fbf97118253b0a9c6b4de29ac88573) | success |
| 6f | agent tries to pay through the **old** (pre-panic) session | [0x7310bcc7…](https://testnet.bscscan.com/tx/0x7310bcc7d20efa8396e7eb61c55b3b3738a8e0e484728955b5bbf373542648d0) | **rejected**: `PolicyInactive` |
| W1 | attacker with the **stolen admin key** schedules `addDestination(0xBAD1)` | [0x7aa83e7b…](https://testnet.bscscan.com/tx/0x7aa83e7bf27bcb13b6a6f28f2a211dfa77b828d86dd956788537e366c4230218) | success (the change waits in the 1-hour timelock) |
| W2 | **Watchtower** (guardian2 key) cancels it, 5 blocks later | [0x6b0875eb…](https://testnet.bscscan.com/tx/0x6b0875eba8f33b562ea4d0fbd2853eda20b87b3e4901e8a79c745b32f4211714) | success |
| W3 | attacker tries to execute the change anyway | [0x3c6846b8…](https://testnet.bscscan.com/tx/0x3c6846b88003723f973912493a364a6f3c1797e983b6ad5e09e937c23ca29f1a) | **rejected**: `UnknownOperation` |

Machine-readable copies: `deployments/bsc-testnet/epk-v2.json`, `epk-v2-vault.json`,
`epk-v2-attacks.json`, `epk-v2-attacks-results.json`.

### Check it yourself

No need to trust this page. The same claims are written in machine-readable form in
`deployments/bsc-testnet/epk-v2-evidence.json`, and one command (Python 3 only — no Foundry, no
keys, no packages) checks every one of them against a public BSC Testnet node:

```bash
python scripts/v2/verify_evidence.py            # add --build after `forge build` to compare bytecode with this repo
```

| What | How it is checked |
|---|---|
| Network | `chainId` must be 97 |
| This page = the evidence file | both list exactly the same transactions and contracts |
| Code | every contract has code; its keccak256 hash is printed; vault implementations must match the hash **pinned in EPKRegistry**; the release event's hash must equal the deployed code; the vault's EIP-1967 slot must point to the claimed implementation; with `--build` the on-chain bytecode must equal this repository's compiled bytecode (immutables masked) |
| Who did what | every transaction was sent by the claimed role to the claimed contract |
| Successful steps | the claimed events were emitted by the claimed contract, with the claimed indexed values and amounts (e.g. `Transfer` of exactly 50 eUSD from the vault to the treasury) |
| Rejected steps | failed by revert, not by running out of gas, and the claimed custom error is proven in the strongest available way — the report labels which: **STRICT** = read from the execution trace of that exact transaction (live, or a trace saved in `deployments/bsc-testnet/traces/` whose sender, target and input match the transaction); **REPLAY** = the same transaction replayed against the chain state right before its block, plus a check that no earlier transaction in that block was sent to the vault or the token. A replay is strong evidence but not a trace: internal calls from other contracts in the same block cannot be ruled out without one |
| Money | for each attack window, the vault balance before the first attack equals the balance after the last one (nothing moved) |
| History | fixed block-number checkpoints (paused, implementation, balance, limits left). **STATE** = read from the node's historical state; when the node no longer keeps it, **EVENTS** = derived from event logs (pause/unpause, `Upgraded`, eUSD `Transfer`s, `Outflow`), which full nodes keep for good. A value that needs old state and cannot be derived from events is reported as **OLD** (needs an archive node) — never as passed |
| Code hashes | recorded in the evidence file for every contract, including both vault implementations (2.0.0 now, 2.0.1 after the upgrade) |

Why some reasons are REPLAY: free public BSC Testnet nodes do not keep traces of old transactions.
Binance's own node traces only roughly the last 120 blocks (about 1.5 minutes), so from the
recovery step on, `demo_attacks.py` captures each attack's trace immediately after sending it.
The Day 0 attacks (4a–4e) were sent before this was in place, so their reasons are proven by replay.

**How long history lasts.** Free public nodes keep historical *state* only for recent blocks: on
2026-11-07, about two hours after Day 0, `publicnode` already answered "state … is pruned" for the
Day 0 blocks, and no keyless public node had it. Transactions, receipts and event logs stay
available. So:

- checkpoints and attack windows fall back to EVENTS (see the table above) and stay checkable;
- the five Day 0 replays (4a–4e) and two "limit left" values now need an archive node
  (`--rpc-url <archive node>`; paid providers offer them). They were checked while public nodes still
  had the state, and those runs are archived in
  [`deployments/bsc-testnet/verification/`](../deployments/bsc-testnet/verification/):
  `2026-11-07-day0-report.txt`, `2026-11-07-recovery-report.txt` (111 OK, all five replays) and a
  later report with a snapshot of every raw node answer it used (`*-rpc-snapshot.json`,
  `--archive <file>`);
- from now on each milestone is verified right away and archived the same day.

The same checks also run in any browser, with no installation: [`docs/proof/index.html`](proof/index.html)
("EPK Proof of Security") loads the evidence file **from a fixed Git commit** (so the claims it
checks cannot be changed afterwards) and checks it live against the chain. Preview it locally
without exposing the rest of the repository:

```bash
python -m http.server 8765 --bind 127.0.0.1 --directory docs    # then open http://127.0.0.1:8765/proof/
```

Exit code 0 = everything checkable matches (details that need an archive node are listed as OLD),
1 = a mismatch, 2 = something could not be checked. A test with
four planted false claims (an attack "succeeded", a wrong rejection reason, a wrong balance, a wrong
amount) produced four `BAD` lines and exit code 1.

Last run 2026-11-07, after the recovery (with `--build`): **111 checks OK, 0 mismatches, 0 not
checkable**. The on-chain bytecode of all 6 contracts equals this repository's build. Rejection
reasons: 6f `PolicyInactive()` (the pre-panic session) proven **STRICT** by its execution trace;
4a–4e proven by **REPLAY** — `BudgetExceeded(token, 60 eUSD, 50.0116 eUSD)` (the session budget
refills slowly over the day), `DestinationNotAllowed(0x…dEaD)`, `CallNotAllowed()`,
`BadSignature()`, `AgentNotAllowed()`. Money moved during both attack windows: 0 eUSD. Vault after
recovery: unpaused, 9,940 eUSD (10,000 − 50 − 10), new session budget left 90 eUSD.

Run at 13:39 UTC the same day, after `publicnode` had pruned the Day 0 state (with `--build`):
**99 checks OK, 0 mismatches, 7 OLD** (the five Day 0 replays and two limit values; Day 0 balances,
pause state, implementation and the attack window were re-derived from event logs).

About the pause: lifting it is never automatic. Only the admin can schedule `unpause`, it waits
out the timelock (1 hour in this demo), the admin then executes it, and during the wait the
guardians or the recovery key can cancel it. Another `panic` invalidates it as well.
