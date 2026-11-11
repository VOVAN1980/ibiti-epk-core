# SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
# Copyright (c) 2026 Volodymyr Podkorytov (IBITI Labs). See LICENSE.
"""Unit tests for the Watchtower's hashing, decisions and alerts (no network, no keys).

Run: python -m unittest discover -s watchtower -p "test_*.py" -v
"""
import hashlib
import hmac
import json
import os
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import epk_watchtower as wt  # noqa: E402

VAULT = "0xb2166241d29c50f4678aebb5061504ee562fa340"
RELEASE = "0x6f3AFE980F6f0510581d85907e9a276D5996961b"
ATTACKER = "0x000000000000000000000000000000000000bad1"
ADMIN = "0xa2bd166173925e5b8e640f091b0f3becbbbe15f8"

# reference values computed independently: by the deployed vault itself (upgrade) and by Foundry's cast
UPGRADE_ID = "0x41e3edcc906bdc22a5d53e69089a7d08925d0740f878ae00cfd8d86fc0a5aca5"
STOLEN_DATA = "0x678f3ef3000000000000000000000000000000000000000000000000000000000000bad1"
STOLEN_SALT = "0x6e7388d82f1d779c21f76f5d8a887c177250fcb381444892453555330d9c14c5"
STOLEN_ID = "0x39dc2dd509b510b2d7c2899dc9d3e94cf3fd323df6aa0588200bb667bbe1d6f6"


def scheduled_log(data, salt, ready_at=1_800_000_000, by=ADMIN):
    """A synthetic OperationScheduled(bytes32 indexed id, bytes data, bytes32 salt, uint64 readyAt, address indexed by)."""
    raw = bytes.fromhex(data[2:])
    body = (wt.word(96) + wt.word(salt) + wt.word(ready_at) + wt.word(len(raw))
            + raw.hex().ljust(((len(raw) + 31) // 32) * 64, "0"))
    return {"address": VAULT, "topics": [wt.EV["OperationScheduled"], wt.operation_id(data, salt), "0x" + wt.word(by)],
            "data": "0x" + body, "blockNumber": "0x1", "logIndex": "0x0"}


def executed_log(op_id):
    return {"address": VAULT, "topics": [wt.EV["OperationExecuted"], op_id], "data": "0x", "blockNumber": "0x2", "logIndex": "0x0"}


def fresh_state():
    return {"lastBlock": None, "unexpected": [], "panicked": False, "seen": {}, "actions": []}


EXPECTED = wt.expected_ids([{"label": "upgrade 2.0.1", "upgradeTo": RELEASE, "salt": "EPK demo: upgrade to 2.0.1"}])
POLICY = {"panicAfterUnexpectedPerHour": 3}


def kinds(actions):
    return [a[0] for a in actions]


class Hashing(unittest.TestCase):
    def test_keccak_vectors(self):
        self.assertEqual(wt.keccak(b"").hex(), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        self.assertEqual(wt.selector("transfer(address,uint256)"), "0xa9059cbb")

    def test_upgrade_operation_id_matches_the_vault(self):
        self.assertEqual(list(EXPECTED), [UPGRADE_ID])

    def test_operation_id_matches_foundry(self):
        self.assertEqual(wt.salt_of("EPK demo: stolen admin key"), STOLEN_SALT)
        self.assertEqual(wt.operation_id(STOLEN_DATA, STOLEN_SALT), STOLEN_ID)

    def test_describe_and_decode(self):
        self.assertIn("allow payments to a new address", wt.describe_call(STOLEN_DATA))
        self.assertIn(ATTACKER, wt.describe_call(STOLEN_DATA))
        op = wt.decode_scheduled(scheduled_log(STOLEN_DATA, STOLEN_SALT, 1_800_000_123))
        self.assertEqual((op["id"], op["data"], op["salt"], op["readyAt"], op["by"]),
                         (STOLEN_ID, STOLEN_DATA, STOLEN_SALT, 1_800_000_123, ADMIN))


class Decisions(unittest.TestCase):
    def test_approved_change_is_left_alone(self):
        st = fresh_state()
        acts = wt.decide(scheduled_log(wt.upgrade_data(RELEASE), wt.salt_of("EPK demo: upgrade to 2.0.1")), EXPECTED, st, 0, POLICY)
        self.assertEqual(kinds(acts), ["alert"])
        self.assertEqual(acts[0][1], "info")
        self.assertEqual(st["seen"][UPGRADE_ID], "expected")

    def test_unexpected_change_is_cancelled(self):
        acts = wt.decide(scheduled_log(STOLEN_DATA, STOLEN_SALT), EXPECTED, fresh_state(), 0, POLICY)
        self.assertEqual(kinds(acts), ["alert", "cancel"])
        self.assertEqual(acts[0][1], "critical")
        self.assertEqual(acts[1][1], STOLEN_ID)

    def test_burst_of_unexpected_changes_triggers_panic_once(self):
        st = fresh_state()
        for i, now in enumerate((0, 600, 1200)):
            acts = wt.decide(scheduled_log(STOLEN_DATA, wt.salt_of(f"attempt {i}")), EXPECTED, st, now, POLICY)
        self.assertEqual(kinds(acts), ["alert", "cancel", "panic"])
        st["panicked"] = True
        acts = wt.decide(scheduled_log(STOLEN_DATA, wt.salt_of("attempt 3")), EXPECTED, st, 1300, POLICY)
        self.assertNotIn("panic", kinds(acts))

    def test_old_unexpected_changes_do_not_count(self):
        st = fresh_state()
        for i, now in enumerate((0, 4000, 8000)):
            acts = wt.decide(scheduled_log(STOLEN_DATA, wt.salt_of(f"slow {i}")), EXPECTED, st, now, POLICY)
        self.assertEqual(kinds(acts), ["alert", "cancel"])

    def test_unapproved_execution_panics(self):
        acts = wt.decide(executed_log(STOLEN_ID), EXPECTED, fresh_state(), 0, POLICY)
        self.assertEqual(kinds(acts), ["alert", "panic"])

    def test_approved_execution_is_fine(self):
        acts = wt.decide(executed_log(UPGRADE_ID), EXPECTED, fresh_state(), 0, POLICY)
        self.assertEqual(kinds(acts), ["alert"])
        self.assertEqual(acts[0][1], "info")

    def test_failed_cancel_escalates(self):
        st = fresh_state()
        self.assertEqual(kinds(wt.after_failed_cancel(STOLEN_ID, st)), ["alert", "panic"])
        st["panicked"] = True
        self.assertEqual(kinds(wt.after_failed_cancel(STOLEN_ID, st)), ["alert"])

    def test_guardian_removal_calls_for_another_guardian(self):
        g = "0x00000000000000000000000000000000000000aa"
        for data in ("0x" + wt.selector("replaceGuardian(address,address)")[2:] + wt.word(g) + wt.word(ATTACKER),
                     "0x" + wt.selector("setGuardian(address,bool)")[2:] + wt.word(g) + wt.word(0)):
            acts = wt.decide(scheduled_log(data, STOLEN_SALT), EXPECTED, fresh_state(), 0, POLICY)
            self.assertEqual(kinds(acts), ["alert", "alert", "cancel"])
            self.assertIn("GUARDIAN REMOVAL of " + g, acts[1][2])
        adding = "0x" + wt.selector("setGuardian(address,bool)")[2:] + wt.word(g) + wt.word(1)
        self.assertIsNone(wt.removed_guardian(adding))

    def test_recovery_replacement_raises_the_alarm(self):
        data = "0x" + wt.selector("setRecovery(address)")[2:] + wt.word(ATTACKER)
        acts = wt.decide(scheduled_log(data, STOLEN_SALT), EXPECTED, fresh_state(), 0, POLICY)
        self.assertEqual(kinds(acts), ["alert", "alert", "cancel"])
        self.assertIn("RECOVERY KEY REPLACEMENT", acts[1][2])

    def test_cold_wallet_change_raises_the_alarm(self):
        data = "0x" + wt.selector("setColdWallet(address)")[2:] + wt.word(ATTACKER)
        acts = wt.decide(scheduled_log(data, STOLEN_SALT), EXPECTED, fresh_state(), 0, POLICY)
        self.assertEqual(kinds(acts), ["alert", "alert", "cancel"])
        self.assertIn("COLD WALLET CHANGE", acts[1][2])

    def test_unpause_rearms_panic(self):
        st = fresh_state()
        st["panicked"] = True
        unpaused = {"address": VAULT, "topics": [wt.EV["Unpaused"]], "data": "0x"}
        wt.decide(unpaused, EXPECTED, st, 0, POLICY)
        self.assertFalse(st["panicked"])

    def test_other_events_only_alert(self):
        paused = {"address": VAULT, "topics": [wt.EV["Paused"], "0x" + wt.word(ADMIN)], "data": "0x"}
        self.assertEqual(kinds(wt.decide(paused, EXPECTED, fresh_state(), 0, POLICY)), ["alert"])


TOKEN = "123456:SECRET-BOT-TOKEN"


class Recorder:
    """A fake HTTP transport: records what would be posted."""

    def __init__(self, fail_times=0, block=None):
        self.calls, self.fail_times, self.block = [], fail_times, block

    def __call__(self, url, body, headers, timeout=15):
        if self.block:
            self.block.wait(5)
        if self.fail_times:
            self.fail_times -= 1
            raise OSError("network down")
        self.calls.append((url, body, headers))
        return 200


class Alerts(unittest.TestCase):
    ALERT = wt.make_alert("critical", "UNEXPECTED change scheduled — cancelling 0xabc", VAULT, 97, now=1_800_000_000)

    def test_alert_payload(self):
        self.assertEqual(self.ALERT, {"source": wt.VERSION, "time": "2027-01-15T08:00:00Z", "level": "critical",
                                      "vault": VAULT, "chainId": 97,
                                      "text": "UNEXPECTED change scheduled — cancelling 0xabc"})

    def test_telegram_message(self):
        post = Recorder()
        wt.TelegramChannel(TOKEN, "-100777", explorer="https://testnet.bscscan.com", post=post).deliver(self.ALERT)
        (url, body, headers), = post.calls
        self.assertEqual(url, f"https://api.telegram.org/bot{TOKEN}/sendMessage")
        msg = json.loads(body)
        self.assertEqual(msg["chat_id"], "-100777")
        self.assertTrue(msg["text"].startswith("🔴 CRITICAL · EPK Watchtower\nUNEXPECTED change scheduled"))
        self.assertIn(f"https://testnet.bscscan.com/address/{VAULT}", msg["text"])
        self.assertNotIn(TOKEN, json.dumps(headers))

    def test_webhook_is_signed(self):
        post = Recorder()
        wt.WebhookChannel("https://example.test/hook", secret="s3cret", post=post).deliver(self.ALERT)
        (url, body, headers), = post.calls
        self.assertEqual(json.loads(body), self.ALERT)
        ts = headers["X-EPK-Timestamp"]
        want = "sha256=" + hmac.new(b"s3cret", ts.encode() + b"." + body, hashlib.sha256).hexdigest()
        self.assertEqual(headers["X-EPK-Signature"], want)
        unsigned = Recorder()
        wt.WebhookChannel("https://example.test/hook", post=unsigned).deliver(self.ALERT)
        self.assertNotIn("X-EPK-Signature", unsigned.calls[0][2])

    def test_levels_per_channel(self):
        tg, hook = Recorder(), Recorder()
        d = wt.Dispatcher([wt.TelegramChannel(TOKEN, "1", "warning", post=tg), wt.WebhookChannel("u", min_level="info", post=hook)])
        d.submit(wt.make_alert("info", "expected change scheduled", VAULT, 97))
        d.submit(wt.make_alert("info", "watching vault", VAULT, 97), force=True)
        self.assertTrue(d.flush(5))
        self.assertEqual(len(tg.calls), 1)   # only the forced one (startup / heartbeat)
        self.assertEqual(len(hook.calls), 2)  # the webhook takes everything

    def test_retries_then_gives_up_without_leaking_the_token(self):
        errors = []
        flaky, dead = Recorder(fail_times=2), Recorder(fail_times=99)
        d = wt.Dispatcher([wt.TelegramChannel(TOKEN, "1", post=flaky), wt.WebhookChannel("u", post=dead)],
                          on_error=errors.append, sleep=lambda s: None)
        d.submit(self.ALERT)
        self.assertTrue(d.flush(5))
        self.assertEqual(len(flaky.calls), 1)  # delivered on the third try
        self.assertEqual(errors, ["webhook alert not delivered after 3 tries: OSError"])
        self.assertNotIn(TOKEN, " ".join(errors))

    def test_channels_from_environment(self):
        keys = ("TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "WATCHTOWER_WEBHOOK_URL", "WATCHTOWER_WEBHOOK_SECRET")
        saved = {k: os.environ.pop(k, None) for k in keys}
        try:
            cfg = {"envFile": "does-not-exist.env"}
            self.assertEqual(wt.build_channels(cfg), [])
            os.environ.update({"TELEGRAM_BOT_TOKEN": TOKEN, "TELEGRAM_CHAT_ID": "1", "WATCHTOWER_WEBHOOK_URL": "https://example.test"})
            self.assertEqual([c.name for c in wt.build_channels(cfg)], ["telegram", "webhook"])
        finally:
            for k, v in saved.items():
                os.environ.pop(k, None)
                if v is not None:
                    os.environ[k] = v


class AlertsNeverDelayACancel(unittest.TestCase):
    def test_slow_channel_does_not_hold_up_the_cancel(self):
        tmp = tempfile.mkdtemp()
        cfg = {"rpc": "http://127.0.0.1:1", "chainId": 97, "vault": VAULT, "guardianKeyEnv": "NO_SUCH_KEY",
               "envFile": os.path.join(tmp, "none.env"), "stateFile": os.path.join(tmp, "state.json"),
               "alerts": {"logFile": os.path.join(tmp, "alerts.log")}}
        tower = wt.Watchtower(cfg)
        gate = threading.Event()
        tower.dispatcher = wt.Dispatcher([wt.WebhookChannel("u", post=Recorder(block=gate))])
        sent = []
        tower.send = lambda sig, *args: (sent.append((sig, args, time.time())) or ("0xtx", True))
        start = time.time()
        tower.act([("alert", "critical", "UNEXPECTED change"), ("cancel", STOLEN_ID)])
        self.assertEqual(sent[0][:2], ("cancel(bytes32)", (STOLEN_ID,)))
        self.assertLess(sent[0][2] - start, 0.5)  # the webhook is still stuck; the cancel already went out
        gate.set()
        self.assertTrue(tower.dispatcher.flush(10))

    def test_heartbeat(self):
        tmp = tempfile.mkdtemp()
        cfg = {"rpc": "http://127.0.0.1:1", "chainId": 97, "vault": VAULT, "guardianKeyEnv": "NO_SUCH_KEY",
               "envFile": os.path.join(tmp, "none.env"), "stateFile": os.path.join(tmp, "state.json"),
               "alerts": {"logFile": os.path.join(tmp, "alerts.log"), "heartbeatHours": 24}}
        tower = wt.Watchtower(cfg)
        tg = Recorder()
        tower.dispatcher = wt.Dispatcher([wt.TelegramChannel(TOKEN, "1", "warning", post=tg)])
        tower.heartbeat(now=tower.last_heartbeat + 3600)
        tower.heartbeat(now=tower.last_heartbeat + 25 * 3600)
        self.assertTrue(tower.dispatcher.flush(5))
        self.assertEqual(len(tg.calls), 1)
        self.assertIn("still watching", json.loads(tg.calls[0][1])["text"])


if __name__ == "__main__":
    unittest.main()
