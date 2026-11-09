# EPK Watchtower

An automatic guardian for an EPK v2 vault. Status: **working on BSC Testnet** (live demo
below); not audited; licensed under the IBITI Labs EPK License ([`LICENSE`](../LICENSE)) like the rest of EPK.

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
python -m unittest discover -s watchtower -p "test_*.py" -v                                # 16 tests, no network
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

1. The Watchtower watches the demo vault `0x1538f0Ce…bD4Db` (EPKVault 2.3.0, 5-minute timelock) with the
   guardian2 key; `config.bsc-testnet.json` pre-approves nothing, so every scheduled change is treated as
   unexpected.
2. An attacker who holds the **real admin key** schedules `addDestination(0xBAD1)` — the one change
   that would let money leave the vault for their own address
   ([0x898a5c22…](https://testnet.bscscan.com/tx/0x898a5c22176a44ddd08ca83050609df076cbe15b10e7e3a0414c3a2a9603cf29), block 141607584).
3. The Watchtower cancels it **9 blocks (about 4 seconds) later**
   ([0xf840e927…](https://testnet.bscscan.com/tx/0xf840e92713ec0609e82298b8ba8df6dbd938df88268a585c1c959318e26762c0), block 141607593).
4. The attacker tries to execute the change anyway and is rejected with `UnknownOperation()` — the
   change no longer exists (proven by the execution trace of that transaction;
   [0x546714e9…](https://testnet.bscscan.com/tx/0x546714e9af91412eaca6336e769a5a49cc6eac9d39d2ab5e5e7932360de9e550)).
   `0xBAD1` never became an allowed destination; the vault balance stayed 9,940 eUSD.
5. The attacker then tries the emergency route: `setColdWallet(0xBAD2)`, so that an evacuation would pay
   them ([0x4ed25a8a…](https://testnet.bscscan.com/tx/0x4ed25a8ac08934553869fd13710baf836a929a4ce3e3744d01ad181a79485942)). The Watchtower raises the **COLD WALLET CHANGE** alarm and
   cancels it **6 blocks (about 3 seconds) later** ([0x6a53e86e…](https://testnet.bscscan.com/tx/0x6a53e86e0e4278b8ccf87ecaf6c92043273a35ec6cf1f3bd8cada37a91756b4c)); executing it anyway
   fails with `UnknownOperation()`. The owner's recovery key then evacuates all 9,940 eUSD to the cold wallet
   registered at setup ([0xa36d6be2…](https://testnet.bscscan.com/tx/0xa36d6be26185ed11fe75ac4c83ee99741faa82956663f25a5946b0169a9da3ba)), and the Watchtower reports the vault paused.

The Watchtower's own log of that run: `deployments/bsc-testnet/watchtower/2026-11-08-alerts.log`.
All of it is re-checked by `scripts/v2/verify_evidence.py` (steps W1–W3 and E1–E5, [`docs/TESTNET_V2.md`](../docs/TESTNET_V2.md)).

Rehearsed on a local fork as well: the attack above, an approved upgrade (left alone), and a burst of
three unexpected changes (each cancelled, then `panic`).

## Not yet

- Notifications other than Telegram; a hosted, always-on deployment; several vaults per process.
- Approving changes by a signed message from the owner instead of editing the config.
- A TypeScript version in SDK v2.
