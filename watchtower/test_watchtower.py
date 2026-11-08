# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Volodymyr Podkorytov (IBITI Labs). See LICENSE-BUSL-1.1.
"""Unit tests for the Watchtower's hashing and decisions (no network, no keys).

Run: python -m unittest discover -s watchtower -p "test_*.py" -v
"""
import os
import sys
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

    def test_unpause_rearms_panic(self):
        st = fresh_state()
        st["panicked"] = True
        unpaused = {"address": VAULT, "topics": [wt.EV["Unpaused"]], "data": "0x"}
        wt.decide(unpaused, EXPECTED, st, 0, POLICY)
        self.assertFalse(st["panicked"])

    def test_other_events_only_alert(self):
        paused = {"address": VAULT, "topics": [wt.EV["Paused"], "0x" + wt.word(ADMIN)], "data": "0x"}
        self.assertEqual(kinds(wt.decide(paused, EXPECTED, fresh_state(), 0, POLICY)), ["alert"])


if __name__ == "__main__":
    unittest.main()
