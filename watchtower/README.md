# EPK Watchtower

An automatic guardian for an EPK v2 vault. Status: **working on BSC Testnet** (live demo on
2026-11-07, see below); not audited; licensed under BUSL-1.1 like the rest of EPK v2.

## Why it exists

An `EPKVault` never applies a loosening change at once — a new payment destination, a higher limit,
a new admin, weaker guardians, a shorter delay, an upgrade. The change waits in a timelock, and
during the wait any guardian can cancel it. That is what protects a customer whose admin key or
server is stolen: the thief's change can be stopped before it takes effect.

But it only helps if somebody is watching. People sleep, travel and miss notifications. The
Watchtower watches instead: it is a guardian that never sleeps.

## What it does

| Event in the vault | Watchtower |
|---|---|
| A change the owner approved in advance (listed in the config) is scheduled | leaves it alone, logs it |
| **Any other change is scheduled** | **cancels it at once** with its guardian key, sends an alert |
| A cancel fails, or 3 unexpected changes arrive within an hour | presses `panic()` (pause + revoke all sessions, policies and pending changes) |
| A change that was not approved gets executed | presses `panic()` |
| Pause, admin change, epoch bump, guardian / delay / destination change | sends an alert |

It only uses a guardian's own buttons, `cancel(id)` and `panic()`. A guardian can never move funds,
so even a stolen Watchtower key can at worst pause the vault, which the owner lifts through the
timelock. Run the Watchtower on a different machine from the admin key — that is the point.

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

## Live demo on BSC Testnet (2026-11-07) — "the admin key was stolen"

1. The Watchtower watches the demo vault `0xB2166241…A340` with the guardian2 key; the only approved
   change is the planned upgrade to release 2.0.1.
2. An attacker who holds the **real admin key** schedules `addDestination(0xBAD1)` — the one change
   that would let money leave the vault for their own address
   ([0x7aa83e7b…](https://testnet.bscscan.com/tx/0x7aa83e7bf27bcb13b6a6f28f2a211dfa77b828d86dd956788537e366c4230218), block 141354342).
3. The Watchtower cancels it **5 blocks (about 3–4 seconds) later**
   ([0x6b0875eb…](https://testnet.bscscan.com/tx/0x6b0875eba8f33b562ea4d0fbd2853eda20b87b3e4901e8a79c745b32f4211714), block 141354347).
4. The attacker tries to execute the change anyway and is rejected with `UnknownOperation()` — the
   change no longer exists (proven by the execution trace of that transaction;
   [0x3c6846b8…](https://testnet.bscscan.com/tx/0x3c6846b88003723f973912493a364a6f3c1797e983b6ad5e09e937c23ca29f1a)).
   `0xBAD1` never became an allowed destination; the vault balance stayed 9,940 eUSD.

The Watchtower's own log of that run: `deployments/bsc-testnet/watchtower/2026-11-07-alerts.log`.
All of it is re-checked by `scripts/v2/verify_evidence.py` (steps W1–W3).

Rehearsed first on a local fork: the attack above, the approved 2.0.1 upgrade (left alone), and a
burst of three unexpected changes (each cancelled, then `panic`).

## Not yet

- Notifications other than Telegram; a hosted, always-on deployment; several vaults per process.
- Approving changes by a signed message from the owner instead of editing the config.
- A TypeScript version in SDK v2.
