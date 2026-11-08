# EPK Watchtower

An automatic guardian for an EPK v2 vault. Status: **working on BSC Testnet** (live demo
below); not audited; licensed under BUSL-1.1 like the rest of EPK v2.

## Why it exists

An `EPKVault` never applies a loosening change at once — a new payment destination, a higher limit,
a new admin, weaker guardians, a shorter delay, an upgrade. The change waits in a timelock, and
during the wait any guardian can cancel it. That is what protects a customer whose admin key or
server is stolen: the thief's change can be stopped before it takes effect.

But it only helps if somebody is watching. People sleep, travel and miss notifications. The
Watchtower watches instead: a guardian that keeps watching as long as it runs (always-on hosting is the next step).

## What it does

| Event in the vault | Watchtower |
|---|---|
| A change the owner approved in advance (listed in the config) is scheduled | leaves it alone, logs it |
| **Any other change is scheduled** | **cancels it at once** with its guardian key, sends an alert |
| A cancel fails, or 3 unexpected changes arrive within an hour | presses `panic()` (pause + revoke all sessions, policies and pending changes) |
| A change that was not approved gets executed | presses `panic()` |
| Pause, admin change, epoch bump, guardian / delay / destination change | sends an alert |
| A change would remove a guardian | cancels it if it can and raises a **GUARDIAN REMOVAL** alarm: the removed guardian cannot veto its own removal, so another guardian or the owner must |
| The node cannot be read 5 times in a row | sends an alert (the vault is not being watched) |

It only uses a guardian's own buttons, `cancel(id)` and `panic()`. A guardian can never move funds,
so even a stolen Watchtower key can at worst pause or panic the vault (panic also revokes policies,
sessions and pending changes) and veto the owner's changes until it is replaced through the timelock.
One Watchtower cannot stop its own removal: run two, on separate hosts, with separate guardian keys. Run the Watchtower on a different machine from the admin key — that is the point.

A `panic` also invalidates changes the owner approved; the owner simply schedules them again once
the incident is over.

## Run it

```bash
python watchtower/epk_watchtower.py --config watchtower/config.bsc-testnet.json            # live
python watchtower/epk_watchtower.py --config watchtower/config.bsc-testnet.json --dry-run  # decide only, send nothing
python -m unittest discover -s watchtower -p "test_*.py" -v                                # 12 tests, no network
```

- Python 3.8+, no packages (its own keccak256). Signing uses Foundry's `cast`.
- Config (`config.bsc-testnet.json`) holds no secrets: the guardian key is read from the environment
  variable or `.env` entry named in `guardianKeyEnv` and is never printed or written.
- `expected` lists the owner's pre-approved changes, either as an upgrade
  (`{"upgradeTo": <release>, "salt": "<text>"}`), as `{"data": "0x…", "salt": …}` or as an operation
  `{"id": "0x…"}`. The Watchtower computes ids exactly like `EPKVault.hashOperation`; a unit test
  compares them with the deployed vault and with Foundry.
- Alerts go to the console and `watchtower/alerts.log`; with `TELEGRAM_BOT_TOKEN` and
  `TELEGRAM_CHAT_ID` set (environment or `.env`) also to Telegram.
- Progress is kept in `watchtower/state.json`, so a restart continues where it stopped.

## Live demo on BSC Testnet — "the admin key was stolen"

1. The Watchtower watches the demo vault `0x14026E45…43fa` (EPKVault 2.2.0) with the guardian2 key;
   `config.bsc-testnet.json` pre-approves nothing, so every scheduled change is treated as unexpected.
2. An attacker who holds the **real admin key** schedules `addDestination(0xBAD1)` — the one change
   that would let money leave the vault for their own address
   ([0x0c13847e…](https://testnet.bscscan.com/tx/0x0c13847ef76301c7de2b5cc594c973449b88495ea3aabd70422319436ded6a44), block 141578898).
3. The Watchtower cancels it **4 blocks (about 11 seconds) later**
   ([0x22c88ddb…](https://testnet.bscscan.com/tx/0x22c88ddbab659a89bb9b0e955f54d998e0df692add738f03e7036a4132c559b9), block 141578902).
4. The attacker tries to execute the change anyway and is rejected with `UnknownOperation()` — the
   change no longer exists (proven by the execution trace of that transaction;
   [0x8ae785d2…](https://testnet.bscscan.com/tx/0x8ae785d2cdf7b1919e3897d5fb3c0d73734519514bc0ab3e06e1c1ea6c628144)).
   `0xBAD1` never became an allowed destination; the vault balance stayed 9,940 eUSD.

The Watchtower's own log of that run: `deployments/bsc-testnet/watchtower/2026-11-08-alerts.log`.
All of it is re-checked by `scripts/v2/verify_evidence.py` (steps W1–W3, [`docs/TESTNET_V2.md`](../docs/TESTNET_V2.md)).

Rehearsed on a local fork as well: the attack above, an approved upgrade (left alone), and a burst of
three unexpected changes (each cancelled, then `panic`).

## Not yet

- Notifications other than Telegram; a hosted, always-on deployment; several vaults per process.
- Approving changes by a signed message from the owner instead of editing the config.
- A TypeScript version in SDK v2.
