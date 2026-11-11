# SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
# Copyright (c) 2026 Volodymyr Podkorytov (IBITI Labs). See LICENSE.
"""EPK Watchtower — an automatic guardian for one EPKVault.

The vault already makes every loosening change (new destination, higher limit, new admin, weaker
guardians, shorter delay, upgrade, ...) wait in a timelock, and any guardian may cancel it while it
waits. That protection only works if someone is watching. The Watchtower watches instead of a person:

  * a change the owner approved in advance (listed in the config)  -> left alone, logged;
  * any other scheduled change                                       -> cancelled at once with the
                                                                        guardian key, alert sent;
  * cancel fails, or too many unexpected changes in an hour, or an
    unapproved change gets executed                                  -> panic(): pause + revoke all;
  * pauses, admin changes, epoch bumps, ...                          -> alert.

It only ever calls the guardian's own buttons: `cancel(id)` and `panic()`. A guardian can never move
funds, so a stolen Watchtower key can at worst pause the vault — which the owner undoes through the
timelock. Run it on a different machine than the admin key.

Alerts go to the console and a log file and, when configured, to Telegram and to a webhook (the
customer's own system). They are delivered by a background thread: a slow or broken channel never
delays a cancel or a panic.

Usage:
    python watchtower/epk_watchtower.py --config watchtower/config.bsc-testnet.json [--once] [--dry-run]
    python watchtower/epk_watchtower.py --config ... --test-alert          # send one test alert, exit
    python watchtower/epk_watchtower.py --config ... --telegram-chat-id    # show chats that wrote to the bot

Needs Python 3.8+ (no packages) to watch, and Foundry's `cast` to sign the guardian's responses.
The guardian key, the Telegram bot token and the webhook secret are read from environment variables
or the local, git-ignored .env file and are never printed or written anywhere.
"""
import hashlib
import hmac
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

VERSION = "epk-watchtower/1.1"

# ---------------------------------------------------------------------------------------------
# Keccak-256 in pure Python (kept in this file so the Watchtower can be copied alone to a server)
# ---------------------------------------------------------------------------------------------
_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M = (1 << 64) - 1


def _rol(v, n):
    return ((v << n) | (v >> (64 - n))) & _M


def _keccak_f(s):
    for rc in _RC:
        c = [s[x] ^ s[x + 5] ^ s[x + 10] ^ s[x + 15] ^ s[x + 20] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        s = [s[i] ^ d[i % 5] for i in range(25)]
        b = [0] * 25
        for x in range(5):
            for y in range(5):
                b[y + 5 * ((2 * x + 3 * y) % 5)] = _rol(s[x + 5 * y], _ROT[x][y])
        s = [b[i] ^ (~b[(i + 1) % 5 + 5 * (i // 5)] & b[(i + 2) % 5 + 5 * (i // 5)]) for i in range(25)]
        s[0] ^= rc
    return s


def keccak(data):
    rate, buf = 136, bytearray(data) + b"\x01"
    buf += b"\x00" * (-len(buf) % rate)
    buf[-1] |= 0x80
    s = [0] * 25
    for off in range(0, len(buf), rate):
        for i in range(rate // 8):
            s[i] ^= int.from_bytes(buf[off + 8 * i:off + 8 * i + 8], "little")
        s = _keccak_f(s)
    return b"".join(s[i].to_bytes(8, "little") for i in range(4))


assert keccak(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"


def selector(sig):
    return "0x" + keccak(sig.encode())[:4].hex()


def topic0(sig):
    return "0x" + keccak(sig.encode()).hex()


def word(v):
    return format(int(v, 16) if isinstance(v, str) else int(v), "064x")


# ---------------------------------------------------------------------------------------------
# What the vault can be asked to change through its timelock (for readable alerts)
# ---------------------------------------------------------------------------------------------
TIMELOCKED = {
    "addDestination(address)": "allow payments to a new address",
    "setAsset(address,uint128,uint32,uint128)": "change a spending limit",
    "untrackAsset(address)": "stop limiting a token",
    "setAdmin(address)": "replace the vault admin",
    "setRecovery(address)": "replace the recovery key",
    "setColdWallet(address)": "CHANGE THE COLD WALLET evacuation sends all funds to",
    "setEvacuator(address)": "change who may evacuate the vault to its cold wallet",
    "setGuardian(address,bool)": "add or remove a guardian",
    "replaceGuardian(address,address)": "replace a guardian",
    "setDelay(uint256)": "change the timelock delay",
    "setCoSigner(address)": "change the co-signer",
    "setSessionManager(address)": "change who opens agent sessions",
    "setEnvelope(uint256,bool,uint48,uint128)": "change an agent envelope",
    "setEnvelopeCall(uint256,address,bytes4,bool)": "allow or forbid an agent call",
    "setEnvelopeBudgetCap(uint256,address,uint128)": "change an agent budget",
    "setEnvelopeGuard(uint256,address)": "change the guard of agent sessions (vault 2.1+)",
    "setPolicyActive(uint256,bool)": "switch a policy on or off",
    "setAgent(uint256,address,bool,uint40)": "allow or forbid an agent",
    "setCall(uint256,address,bytes4,bool)": "allow or forbid a policy call",
    "unpause()": "lift a pause",
    "upgradeToAndCall(address,bytes)": "upgrade the vault's code",
}
TIMELOCKED_RU = {
    "addDestination(address)": "разрешить платежи на новый адрес",
    "setAsset(address,uint128,uint32,uint128)": "изменить лимит расходов",
    "untrackAsset(address)": "снять лимит с токена",
    "setAdmin(address)": "заменить администратора сейфа",
    "setRecovery(address)": "заменить ключ восстановления",
    "setColdWallet(address)": "СМЕНИТЬ ХОЛОДНЫЙ КОШЕЛЁК, куда эвакуация отправляет все средства",
    "setEvacuator(address)": "изменить, кто может эвакуировать сейф на холодный кошелёк",
    "setGuardian(address,bool)": "добавить или убрать хранителя",
    "replaceGuardian(address,address)": "заменить хранителя",
    "setDelay(uint256)": "изменить задержку таймлока",
    "setCoSigner(address)": "сменить второго подписанта",
    "setSessionManager(address)": "изменить, кто открывает сессии агентов",
    "setEnvelope(uint256,bool,uint48,uint128)": "изменить рамки агента",
    "setEnvelopeCall(uint256,address,bytes4,bool)": "разрешить или запретить вызов агента",
    "setEnvelopeBudgetCap(uint256,address,uint128)": "изменить бюджет агента",
    "setEnvelopeGuard(uint256,address)": "сменить защиту сессий агентов (сейф 2.1+)",
    "setPolicyActive(uint256,bool)": "включить или выключить политику",
    "setAgent(uint256,address,bool,uint40)": "разрешить или запретить агента",
    "setCall(uint256,address,bytes4,bool)": "разрешить или запретить вызов политики",
    "unpause()": "снять паузу",
    "upgradeToAndCall(address,bytes)": "обновить код сейфа",
}
assert set(TIMELOCKED_RU) == set(TIMELOCKED)
BY_SELECTOR = {selector(sig): (sig, what) for sig, what in TIMELOCKED.items()}

EV = {name: topic0(sig) for name, sig in {
    "OperationScheduled": "OperationScheduled(bytes32,bytes,bytes32,uint64,address)",
    "OperationExecuted": "OperationExecuted(bytes32)",
    "OperationCancelled": "OperationCancelled(bytes32,address)",
    "Paused": "Paused(address)",
    "Unpaused": "Unpaused()",
    "EpochBumped": "EpochBumped(uint64,address)",
    "AdminChanged": "AdminChanged(address,address)",
    "GuardianSet": "GuardianSet(address,bool)",
    "DelaySet": "DelaySet(uint256)",
    "DestinationSet": "DestinationSet(address,bool)",
}.items()}
EV_NAME = {v: k for k, v in EV.items()}


def describe_call(data, lang="en"):
    """Human-readable description of the call an operation would make."""
    sel = data[:10].lower()
    if sel not in BY_SELECTOR:
        return f"{'неизвестный вызов' if lang == 'ru' else 'unknown call'} {sel}"
    sig, what = BY_SELECTOR[sel]
    if lang == "ru":
        what = TIMELOCKED_RU[sig]
    types = [t for t in sig[sig.index("(") + 1:-1].split(",") if t]
    args = []
    for i, t in enumerate(types):
        w_ = data[10 + 64 * i:74 + 64 * i]
        if t == "address":
            args.append("0x" + w_[-40:])
        elif t == "bool":
            args.append(str(int(w_ or "0", 16) != 0))
        elif t == "bytes4":
            args.append("0x" + w_[:8])
        elif t == "bytes":
            args.append("…")
        else:
            args.append(str(int(w_ or "0", 16)))
    return f"{what}: {sig.split('(')[0]}({', '.join(args)})"


def operation_id(data_hex, salt_hex):
    """Same as EPKVault.hashOperation: keccak256(abi.encode(bytes data, bytes32 salt))."""
    data = bytes.fromhex(data_hex[2:])
    enc = bytes.fromhex(word(64) + word(salt_hex)) + len(data).to_bytes(32, "big") + data + b"\x00" * (-len(data) % 32)
    return "0x" + keccak(enc).hex()


def upgrade_data(new_impl):
    """Same as EPKVault.upgradeOperationData: upgradeToAndCall(newImpl, migrate())."""
    return (selector("upgradeToAndCall(address,bytes)") + word(new_impl) + word(64) + word(4)
            + selector("migrate()")[2:].ljust(64, "0"))


def salt_of(s):
    return s if s.startswith("0x") else "0x" + keccak(s.encode()).hex()


def expected_ids(entries):
    """Operation ids the owner approved in advance: {id: label}."""
    out = {}
    for e in entries:
        if "id" in e:
            out[e["id"].lower()] = e["label"]
        else:
            data = upgrade_data(e["upgradeTo"]) if "upgradeTo" in e else e["data"]
            out[operation_id(data, salt_of(e["salt"])).lower()] = e["label"]
    return out


# ---------------------------------------------------------------------------------------------
# Alert texts in several languages. Each customer picks the language per channel ("en", "ru" or
# "en+ru"); a new language is one more column here plus its line in LEVEL_NAMES / LABELS.
# ---------------------------------------------------------------------------------------------
LANGS = ("en", "ru")
LEVEL_NAMES = {"en": {"info": "INFO", "warning": "WARNING", "critical": "CRITICAL"},
               "ru": {"info": "ИНФО", "warning": "ВНИМАНИЕ", "critical": "КРИТИЧНО"}}
LABELS = {"en": {"vault": "Vault", "chain": "chain"}, "ru": {"vault": "Сейф", "chain": "сеть"}}
MESSAGES = {
    "expected_scheduled": {"en": "expected change scheduled ({label}): {what}; ready {when}",
                           "ru": "запланировано заранее одобренное изменение ({label}): {what}; вступит в силу {when}"},
    "unexpected_scheduled": {"en": "UNEXPECTED change scheduled by {by}: {what}; would take effect {when} — cancelling {id}",
                             "ru": "НЕОЖИДАННОЕ изменение запланировал {by}: {what}; вступило бы в силу {when} — отменяю {id}"},
    "guardian_removal": {"en": "GUARDIAN REMOVAL of {guardian}: that guardian cannot veto its own removal (and a panic does "
                               "not stop it) — ANOTHER guardian or the owner must cancel {id} before {when}",
                         "ru": "УДАЛЕНИЕ ХРАНИТЕЛЯ {guardian}: этот хранитель не может отменить собственное удаление (и паника "
                               "его не останавливает) — ДРУГОЙ хранитель или владелец должен отменить {id} до {when}"},
    "cold_wallet_change": {"en": "COLD WALLET CHANGE: if it went through, an evacuation would send every tracked asset to the "
                                 "new address — a guardian or the owner must make sure {id} is cancelled before {when}",
                           "ru": "СМЕНА ХОЛОДНОГО КОШЕЛЬКА: если она пройдёт, эвакуация отправит все отслеживаемые активы на "
                                 "новый адрес — хранитель или владелец должен убедиться, что {id} отменено до {when}"},
    "recovery_replacement": {"en": "RECOVERY KEY REPLACEMENT: from vault 2.2.0 the recovery key cannot veto it — a guardian or "
                                   "the owner must cancel {id} before {when}",
                             "ru": "ЗАМЕНА КЛЮЧА ВОССТАНОВЛЕНИЯ: начиная с сейфа 2.2.0 ключ восстановления не может её "
                                   "отменить — хранитель или владелец должен отменить {id} до {when}"},
    "expected_executed": {"en": "expected change executed ({label})", "ru": "одобренное изменение выполнено ({label})"},
    "unapproved_executed": {"en": "a change that was NOT approved got executed: {id}",
                            "ru": "выполнено НЕОДОБРЕННОЕ изменение: {id}"},
    "cancelled_by": {"en": "change {id} cancelled by {by}", "ru": "изменение {id} отменил {by}"},
    "paused_by": {"en": "vault PAUSED by {by}", "ru": "сейф ПОСТАВЛЕН НА ПАУЗУ, кем: {by}"},
    "unpaused": {"en": "vault unpaused", "ru": "пауза сейфа снята"},
    "epoch_bumped": {"en": "all policies, sessions and pending changes revoked (epoch bumped)",
                     "ru": "все политики, сессии и ожидающие изменения отозваны (новая эпоха)"},
    "admin_changed": {"en": "vault admin changed to {admin}", "ru": "администратор сейфа сменён на {admin}"},
    "setting_changed": {"en": "vault setting changed: {kind}", "ru": "изменена настройка сейфа: {kind}"},
    "cancel_failed_panicked": {"en": "cancel of {id} failed; vault already panicked",
                               "ru": "отменить {id} не удалось; паника в сейфе уже нажата"},
    "cancel_failed": {"en": "cancel of {id} FAILED — pressing panic", "ru": "отменить {id} НЕ УДАЛОСЬ — нажимаю панику"},
    "reason_burst": {"en": "{n} unexpected changes within an hour", "ru": "{n} неожиданных изменения(й) за час"},
    "reason_unapproved": {"en": "an unapproved change was executed", "ru": "выполнено неодобренное изменение"},
    "reason_cancel_failed": {"en": "could not cancel {id}", "ru": "не удалось отменить {id}"},
    "dry_run": {"en": "dry run: would send {call}", "ru": "пробный режим: отправил бы {call}"},
    "no_key": {"en": "no guardian key ({env}) — cannot send {sig}", "ru": "нет ключа хранителя ({env}) — не могу отправить {sig}"},
    "not_sent": {"en": "{sig} not sent: {err}", "ru": "{sig} не отправлено: {err}"},
    "stopped": {"en": "STOPPED: unexpected change {id} cancelled{tx}", "ru": "ОСТАНОВЛЕНО: неожиданное изменение {id} отменено{tx}"},
    "panic": {"en": "PANIC ({reason}): {result}", "ru": "ПАНИКА ({reason}): {result}"},
    "panic_ok": {"en": "tx {tx}", "ru": "tx {tx}"},
    "panic_failed": {"en": "FAILED — call the owner", "ru": "НЕ УДАЛАСЬ — звоните владельцу"},
    "watching": {"en": "watching vault {vault} on chain {chain}; guardian {guardian} ({confirmed}); {n} approved change(s); {mode}",
                 "ru": "слежу за сейфом {vault} в сети {chain}; хранитель {guardian} ({confirmed}); одобренных изменений: {n}; {mode}"},
    "guardian_ok": {"en": "confirmed by the vault", "ru": "подтверждён сейфом"},
    "guardian_bad": {"en": "NOT a guardian of this vault", "ru": "НЕ хранитель этого сейфа"},
    "mode_dry": {"en": "DRY RUN", "ru": "ПРОБНЫЙ РЕЖИМ"},
    "mode_live": {"en": "live", "ru": "боевой режим"},
    "chain_back": {"en": "reading the chain again after {n} failed attempts",
                   "ru": "снова читаю блокчейн после {n} неудачных попыток"},
    "chain_down": {"en": "cannot read the chain ({n} failed attempts in a row): {err} — the vault is NOT being watched",
                   "ru": "не могу прочитать блокчейн ({n} неудачных попыток подряд): {err} — сейф НЕ под наблюдением"},
    "heartbeat": {"en": "still watching; last block {block}; {n} unexpected change(s) cancelled so far",
                  "ru": "на посту; последний блок {block}; отменено неожиданных изменений: {n}"},
    "operator_stop": {"en": "Watchtower stopped by the operator — the vault is NOT being watched",
                      "ru": "Watchtower остановлен оператором — сейф НЕ под наблюдением"},
    "test_alert": {"en": "test alert: if you can read this, the Watchtower can reach you",
                   "ru": "пробная тревога: если вы это читаете, Watchtower может до вас достучаться"},
}
assert all(set(v) == set(LANGS) for v in MESSAGES.values())


def render(lang, key, params):
    out = {}
    for k, v in params.items():
        if isinstance(v, Msg):
            v = text_in(v, lang)
        elif isinstance(v, dict) and "en" in v:
            v = v.get(lang, v["en"])
        out[k] = v
    return MESSAGES[key].get(lang, MESSAGES[key]["en"]).format(**out)


class Msg(str):
    """An alert text: behaves as its English string, and can be rendered in any language in LANGS."""

    def __new__(cls, key, **params):
        s = str.__new__(cls, render("en", key, params))
        s.key, s.params = key, params
        return s


def text_in(msg, lang):
    return render(lang, msg.key, msg.params) if isinstance(msg, Msg) else str(msg)


def languages(spec):
    """"en" | "ru" | "en+ru" -> ["en", "ru"]; unknown parts are ignored, English is the fallback."""
    out = [p for p in str(spec or "en").lower().replace(",", "+").split("+") if p in LANGS]
    return out or ["en"]


def described(data):
    return {lang: describe_call(data, lang) for lang in LANGS}


# ---------------------------------------------------------------------------------------------
# The decision: pure function, unit-tested in test_watchtower.py
# ---------------------------------------------------------------------------------------------
def decode_scheduled(log):
    d = log["data"][2:]
    off = int(d[0:64], 16) * 2
    ln = int(d[off:off + 64], 16) * 2
    return {"id": log["topics"][1].lower(), "by": "0x" + log["topics"][2][-40:], "data": "0x" + d[off + 64:off + 64 + ln],
            "salt": "0x" + d[64:128], "readyAt": int(d[128:192], 16)}


def decide(log, expected, state, now, policy):
    """Return a list of actions for one vault event.

    actions: ("alert", level, text) | ("cancel", op_id) | ("panic", reason)
    state:   {"unexpected": [unix times], "panicked": bool, "seen": {op_id: "expected"|"unexpected"}}
    """
    kind = EV_NAME.get(log["topics"][0])
    acts = []
    if kind == "OperationScheduled":
        op = decode_scheduled(log)
        when = datetime.fromtimestamp(op["readyAt"], timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        what = described(op["data"])
        if op["id"] in expected:
            state["seen"][op["id"]] = "expected"
            acts.append(("alert", "info", Msg("expected_scheduled", label=expected[op["id"]], what=what, when=when)))
            return acts
        state["seen"][op["id"]] = "unexpected"
        state["unexpected"] = [t for t in state["unexpected"] if now - t < 3600] + [now]
        acts.append(("alert", "critical", Msg("unexpected_scheduled", by=op["by"], what=what, when=when, id=op["id"])))
        removed = removed_guardian(op["data"])
        if removed:
            acts.append(("alert", "critical", Msg("guardian_removal", guardian=removed, id=op["id"], when=when)))
        if op["data"][:10].lower() == selector("setColdWallet(address)"):
            acts.append(("alert", "critical", Msg("cold_wallet_change", id=op["id"], when=when)))
        if op["data"][:10].lower() == selector("setRecovery(address)"):
            acts.append(("alert", "critical", Msg("recovery_replacement", id=op["id"], when=when)))
        acts.append(("cancel", op["id"]))
        if len(state["unexpected"]) >= policy.get("panicAfterUnexpectedPerHour", 3) and not state["panicked"]:
            acts.append(("panic", Msg("reason_burst", n=len(state["unexpected"]))))
    elif kind == "OperationExecuted":
        op_id = log["topics"][1].lower()
        if op_id in expected or state["seen"].get(op_id) == "expected":
            acts.append(("alert", "info", Msg("expected_executed", label=expected.get(op_id, op_id))))
        else:
            acts.append(("alert", "critical", Msg("unapproved_executed", id=op_id)))
            if not state["panicked"]:
                acts.append(("panic", Msg("reason_unapproved")))
    elif kind == "OperationCancelled":
        acts.append(("alert", "info", Msg("cancelled_by", id=log["topics"][1], by="0x" + log["topics"][2][-40:])))
    elif kind == "Paused":
        acts.append(("alert", "warning", Msg("paused_by", by="0x" + log["topics"][1][-40:])))
    elif kind == "Unpaused":
        state["panicked"] = False  # the owner resumed the vault: a new attack may need a new panic
        acts.append(("alert", "warning", Msg("unpaused")))
    elif kind == "EpochBumped":
        acts.append(("alert", "warning", Msg("epoch_bumped")))
    elif kind == "AdminChanged":
        acts.append(("alert", "critical", Msg("admin_changed", admin="0x" + log["topics"][2][-40:])))
    elif kind in ("GuardianSet", "DelaySet", "DestinationSet"):
        acts.append(("alert", "warning", Msg("setting_changed", kind=kind)))
    return acts


def removed_guardian(data):
    """The guardian an operation would remove (setGuardian(g, false) / replaceGuardian(g, _)), else None."""
    sel, args = data[:10].lower(), data[10:]
    if len(args) < 128:
        return None
    if sel == selector("replaceGuardian(address,address)") or (
            sel == selector("setGuardian(address,bool)") and int(args[64:128], 16) == 0):
        return "0x" + args[24:64]
    return None


def after_failed_cancel(op_id, state):
    """A cancel that did not go through is itself an emergency."""
    if state["panicked"]:
        return [("alert", "critical", Msg("cancel_failed_panicked", id=op_id))]
    return [("alert", "critical", Msg("cancel_failed", id=op_id)), ("panic", Msg("reason_cancel_failed", id=op_id))]


# ---------------------------------------------------------------------------------------------
# Plumbing: node, signing, alerts, state
# ---------------------------------------------------------------------------------------------
def rpc(url, method, *params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)}).encode()
    req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "epk-watchtower/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.load(r)
    if "error" in out:
        raise RuntimeError(out["error"].get("message", out["error"]))
    return out["result"]


def read_secret(name, env_file):
    if os.environ.get(name):
        return os.environ[name]
    try:
        for line in open(env_file, encoding="utf-8-sig"):
            m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$", line.rstrip("\r\n"))
            if m and m.group(1) == name:
                return m.group(2).strip().strip('"')
    except OSError:
        pass
    return None


# ---------------------------------------------------------------------------------------------
# Alert channels: Telegram and a webhook today; e-mail, Discord, Slack, ... plug in the same way
# (a class with `name`, `min_level` and `deliver(alert)`)
# ---------------------------------------------------------------------------------------------
LEVELS = {"info": 0, "warning": 1, "critical": 2}
ICONS = {"info": "🔵", "warning": "🟠", "critical": "🔴"}


def level_ok(level, minimum):
    return LEVELS.get(level, 2) >= LEVELS.get(minimum, 1)


def make_alert(level, text, vault, chain_id, now=None):
    """The alert as every channel sees it (and as the webhook receives it, as JSON).

    `text` is English; `texts` holds every language; `event` names the kind of alert for machines."""
    t = datetime.fromtimestamp(now if now is not None else time.time(), timezone.utc)
    return {"source": VERSION, "time": t.strftime("%Y-%m-%dT%H:%M:%SZ"), "level": level,
            "event": getattr(text, "key", "message"), "vault": vault, "chainId": chain_id,
            "text": text_in(text, "en"), "texts": {lang: text_in(text, lang) for lang in LANGS}}


def telegram_text(alert, explorer=None, language="en"):
    langs = languages(language)
    texts = alert.get("texts") or {"en": alert["text"]}
    level = " · ".join(dict.fromkeys(LEVEL_NAMES[lg][alert["level"]] for lg in langs))
    lines = [f"{ICONS.get(alert['level'], '🔴')} {level} · EPK Watchtower"]
    lines += [texts.get(lg, alert["text"]) for lg in langs]
    vault_word = " / ".join(dict.fromkeys(LABELS[lg]["vault"] for lg in langs))
    chain_word = " / ".join(dict.fromkeys(LABELS[lg]["chain"] for lg in langs))
    lines += ["", f"{vault_word}: {alert['vault']} ({chain_word} {alert['chainId']})"]
    if explorer:
        lines.append(f"{explorer.rstrip('/')}/address/{alert['vault']}")
    lines.append(alert["time"].replace("T", " ").replace("Z", " UTC"))
    return "\n".join(lines)


def webhook_signature(secret, timestamp, body):
    """HMAC-SHA256 over "<timestamp>.<body>", so the receiver can check sender and freshness."""
    return "sha256=" + hmac.new(secret.encode(), timestamp.encode() + b"." + body, hashlib.sha256).hexdigest()


def http_post(url, body, headers, timeout=15):
    with urllib.request.urlopen(urllib.request.Request(url, body, headers), timeout=timeout) as r:
        return r.status


class TelegramChannel:
    name = "telegram"

    def __init__(self, token, chat, min_level="warning", explorer=None, post=http_post, language="en"):
        self.token, self.chat, self.min_level, self.explorer, self.post = token, chat, min_level, explorer, post
        self.language = language

    def deliver(self, alert):
        body = json.dumps({"chat_id": self.chat, "text": telegram_text(alert, self.explorer, self.language),
                           "disable_web_page_preview": True}).encode()
        self.post(f"https://api.telegram.org/bot{self.token}/sendMessage", body,
                  {"Content-Type": "application/json", "User-Agent": VERSION})


class WebhookChannel:
    name = "webhook"

    def __init__(self, url, secret=None, min_level="info", post=http_post, language="en"):
        self.url, self.secret, self.min_level, self.post, self.language = url, secret, min_level, post, language

    def deliver(self, alert):
        texts = alert.get("texts") or {}
        payload = dict(alert, text="\n".join(texts.get(lg, alert["text"]) for lg in languages(self.language)))
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode()
        ts = str(int(time.time()))
        headers = {"Content-Type": "application/json", "User-Agent": VERSION, "X-EPK-Timestamp": ts}
        if self.secret:
            headers["X-EPK-Signature"] = webhook_signature(self.secret, ts, body)
        self.post(self.url, body, headers)


def build_channels(cfg, post=http_post):
    """Channels whose secrets are present (environment or .env); none -> console and log file only."""
    a, env = cfg.get("alerts", {}), cfg.get("envFile", ".env")
    out = []
    token = read_secret(a.get("telegramTokenEnv", "TELEGRAM_BOT_TOKEN"), env)
    chat = read_secret(a.get("telegramChatEnv", "TELEGRAM_CHAT_ID"), env)
    if token and chat:
        out.append(TelegramChannel(token, chat, a.get("telegramMinLevel", "warning"), cfg.get("explorer"), post,
                                   a.get("telegramLanguage", "en")))
    url = read_secret(a.get("webhookUrlEnv", "WATCHTOWER_WEBHOOK_URL"), env)
    if url:
        out.append(WebhookChannel(url, read_secret(a.get("webhookSecretEnv", "WATCHTOWER_WEBHOOK_SECRET"), env),
                                  a.get("webhookMinLevel", "info"), post, a.get("webhookLanguage", "en")))
    return out


def failure_reason(e):
    """Why a delivery failed, without the URL (a Telegram URL contains the bot token)."""
    if isinstance(e, urllib.error.HTTPError):
        return f"HTTP {e.code}"
    return type(e).__name__


class Dispatcher:
    """Delivers alerts in a background thread, with retries, so alerts never delay a cancel or a panic."""

    def __init__(self, channels, on_error=None, retries=3, backoff=(1, 3, 9), sleep=time.sleep):
        self.channels, self.retries, self.backoff, self.sleep = channels, retries, backoff, sleep
        self.on_error = on_error or (lambda msg: print(f"  ({msg})", flush=True))
        self.q = queue.Queue()
        if channels:
            threading.Thread(target=self._run, name="epk-alerts", daemon=True).start()

    def submit(self, alert, force=False):
        for ch in self.channels:
            if force or level_ok(alert["level"], ch.min_level):
                self.q.put((ch, alert))

    def _run(self):
        while True:
            ch, alert = self.q.get()
            try:
                for attempt in range(self.retries):
                    try:
                        ch.deliver(alert)
                        break
                    except Exception as e:  # noqa: BLE001 — a channel must never stop the Watchtower
                        if attempt == self.retries - 1:
                            self.on_error(f"{ch.name} alert not delivered after {self.retries} tries: {failure_reason(e)}")
                        else:
                            self.sleep(self.backoff[min(attempt, len(self.backoff) - 1)])
            finally:
                self.q.task_done()

    def flush(self, timeout=60):
        """Wait (at most `timeout` seconds) until queued alerts are delivered or given up."""
        end = time.time() + timeout
        while self.q.unfinished_tasks and time.time() < end:
            time.sleep(0.05)
        return not self.q.unfinished_tasks


class Watchtower:
    def __init__(self, cfg, dry_run=False):
        self.cfg, self.dry = cfg, dry_run
        self.url, self.vault = cfg["rpc"], cfg["vault"].lower()
        self.expected = expected_ids(cfg.get("expected", []))
        self.policy = cfg.get("policy", {})
        self.log_file = cfg.get("alerts", {}).get("logFile", "watchtower/alerts.log")
        self.state_file = cfg.get("stateFile", "watchtower/state.json")
        self.key = read_secret(cfg["guardianKeyEnv"], cfg.get("envFile", ".env"))
        try:
            self.state = json.load(open(self.state_file, encoding="utf-8"))
        except (OSError, ValueError):
            self.state = {"lastBlock": None, "unexpected": [], "panicked": False, "seen": {}, "actions": []}
        self.dispatcher = Dispatcher(build_channels(cfg))
        self.last_heartbeat = time.time()

    # -- alerts ----------------------------------------------------------------------------
    def alert(self, level, text, force=False):
        """Console + log file at once; Telegram / webhook in the background (`force`: every channel)."""
        line = f"{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')} [{level.upper()}] {text}"
        print(line, flush=True)
        os.makedirs(os.path.dirname(self.log_file) or ".", exist_ok=True)
        with open(self.log_file, "a", encoding="utf-8") as f:
            f.write(line + "\n")
        self.dispatcher.submit(make_alert(level, text, self.vault, self.cfg.get("chainId")), force=force)

    def heartbeat(self, now=None):
        """A daily "still watching" message, so a silent Watchtower is noticed (heartbeatHours: 0 = off)."""
        now = now if now is not None else time.time()
        hours = self.cfg.get("alerts", {}).get("heartbeatHours", 24)
        if hours and now - self.last_heartbeat >= hours * 3600:
            self.last_heartbeat = now
            cancels = sum(1 for a in self.state["actions"] if a.get("action") == "cancel" and a.get("ok"))
            self.alert("info", Msg("heartbeat", block=self.state["lastBlock"], n=cancels), force=True)

    # -- guardian responses -------------------------------------------------------------------
    def send(self, sig, *args):
        """Sign and send a guardian transaction with cast. Returns (tx hash, ok)."""
        if self.dry:
            self.alert("info", Msg("dry_run", call=f"{sig} {' '.join(args)}"))
            return None, True
        if not self.key:
            self.alert("critical", Msg("no_key", env=self.cfg["guardianKeyEnv"], sig=sig))
            return None, False
        out = subprocess.run(["cast", "send", self.vault, sig, *args, "--rpc-url", self.url, "--json",
                              "--private-key", self.key], capture_output=True, text=True)
        try:
            rc = json.loads(out.stdout)
            return rc.get("transactionHash"), int(rc.get("status", "0x0"), 16) == 1
        except (ValueError, TypeError):
            err = (out.stderr or "").strip().splitlines()
            self.alert("warning", Msg("not_sent", sig=sig, err=err[-1][:200] if err else "no output"))
            return None, False

    def act(self, actions):
        for a in actions:
            if a[0] == "alert":
                self.alert(a[1], a[2])
            elif a[0] == "cancel":
                tx, ok = self.send("cancel(bytes32)", a[1])
                self.state["actions"].append({"action": "cancel", "id": a[1], "tx": tx, "ok": ok})
                if ok:
                    self.alert("critical" if tx else "info", Msg("stopped", id=a[1], tx=f" — tx {tx}" if tx else ""))
                else:
                    self.act(after_failed_cancel(a[1], self.state))
            elif a[0] == "panic" and not self.state["panicked"]:
                tx, ok = self.send("panic()")
                self.state["panicked"] = ok
                self.state["actions"].append({"action": "panic", "reason": a[1], "tx": tx, "ok": ok})
                self.alert("critical", Msg("panic", reason=a[1], result=Msg("panic_ok", tx=tx) if ok else Msg("panic_failed")))

    # -- main loop -------------------------------------------------------------------------------
    def poll(self):
        latest = int(rpc(self.url, "eth_blockNumber"), 16)
        start = self.state["lastBlock"] + 1 if self.state["lastBlock"] is not None else self.cfg.get("startBlock", latest)
        if start == "latest":
            start = latest
        step = 5000
        while start <= latest:
            end = min(start + step - 1, latest)
            try:
                logs = rpc(self.url, "eth_getLogs", {"address": self.vault, "fromBlock": hex(start), "toBlock": hex(end),
                                                     "topics": [list(EV.values())]})
            except (OSError, RuntimeError, ValueError):
                if end == start:
                    raise
                step = max(1, (end - start + 1) // 2)  # e.g. a reply too large for the node: ask for less
                continue
            for lg in sorted(logs, key=lambda x: (int(x["blockNumber"], 16), int(x["logIndex"], 16))):
                self.act(decide(lg, self.expected, self.state, time.time(), self.policy))
            self.state["lastBlock"] = end
            start = end + 1
        os.makedirs(os.path.dirname(self.state_file) or ".", exist_ok=True)
        json.dump(self.state, open(self.state_file, "w", encoding="utf-8"), indent=1)

    def run(self, once=False):
        cid = int(rpc(self.url, "eth_chainId"), 16)
        if cid != self.cfg["chainId"]:
            sys.exit(f"wrong network: chainId {cid}, config says {self.cfg['chainId']}")
        guardian = None
        if self.key:
            out = subprocess.run(["cast", "wallet", "address", "--private-key", self.key], capture_output=True, text=True)
            guardian = out.stdout.strip() or None
        is_g = guardian and int(rpc(self.url, "eth_call", {"to": self.vault, "data": selector("isGuardian(address)") + word(guardian)},
                                    "latest"), 16) == 1
        self.alert("warning" if not is_g else "info",
                   Msg("watching", vault=self.vault, chain=cid, guardian=guardian or "none",
                       confirmed=Msg("guardian_ok") if is_g else Msg("guardian_bad"), n=len(self.expected),
                       mode=Msg("mode_dry") if self.dry else Msg("mode_live")), force=True)
        failures = 0
        try:
            while True:
                try:
                    self.poll()
                    if failures >= 5:
                        self.alert("warning", Msg("chain_back", n=failures))
                    failures = 0
                except Exception as e:  # noqa: BLE001 — a watchtower must never stop on a bad node reply
                    failures += 1
                    print(f"  (node error, retrying: {type(e).__name__}: {e})", flush=True)
                    if failures == 5 or failures % 100 == 0:
                        self.alert("critical", Msg("chain_down", n=failures, err=type(e).__name__))
                if once:
                    return
                self.heartbeat()
                time.sleep(self.cfg.get("pollSeconds", 3))
        except KeyboardInterrupt:
            self.alert("warning", Msg("operator_stop"), force=True)
        finally:
            self.dispatcher.flush(30)

    def test_alert(self):
        """Send one alert through every configured channel and report what was used."""
        names = [c.name for c in self.dispatcher.channels]
        if not names:
            print("no alert channel configured: set TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID and/or "
                  "WATCHTOWER_WEBHOOK_URL (environment or .env)")
            return False
        self.alert("warning", Msg("test_alert"), force=True)
        ok = self.dispatcher.flush(60)
        print(f"test alert handed to: {', '.join(names)}" + ("" if ok else " (still sending after 60 s)"))
        return ok


def telegram_chat_ids(cfg):
    """Chats that have written to the bot recently (Telegram getUpdates), to fill TELEGRAM_CHAT_ID."""
    token = read_secret(cfg.get("alerts", {}).get("telegramTokenEnv", "TELEGRAM_BOT_TOKEN"), cfg.get("envFile", ".env"))
    if not token:
        sys.exit("TELEGRAM_BOT_TOKEN is not set (environment or .env)")
    try:
        with urllib.request.urlopen(f"https://api.telegram.org/bot{token}/getUpdates", timeout=15) as r:
            updates = json.load(r).get("result", [])
    except (OSError, ValueError) as e:
        sys.exit(f"Telegram did not answer: {failure_reason(e)}")
    chats = {}
    for u in updates:
        msg = u.get("message") or u.get("channel_post") or u.get("my_chat_member") or {}
        c = msg.get("chat") or {}
        if "id" in c:
            chats[c["id"]] = c.get("title") or c.get("username") or c.get("first_name") or c.get("type", "")
    if not chats:
        print("no chats yet: send any message to your bot (or add it to a group and write there), then run this again")
    for cid, name in chats.items():
        print(f"TELEGRAM_CHAT_ID={cid}    # {name}")


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    if "--config" not in sys.argv:
        sys.exit(__doc__)
    cfg = json.load(open(sys.argv[sys.argv.index("--config") + 1], encoding="utf-8"))
    for flag in ("--rpc-url", "--state-file", "--log-file"):
        if flag in sys.argv:
            val = sys.argv[sys.argv.index(flag) + 1]
            if flag == "--rpc-url":
                cfg["rpc"] = val
            elif flag == "--state-file":
                cfg["stateFile"] = val
            else:
                cfg.setdefault("alerts", {})["logFile"] = val
    if "--telegram-chat-id" in sys.argv:
        return telegram_chat_ids(cfg)
    tower = Watchtower(cfg, dry_run="--dry-run" in sys.argv)
    if "--test-alert" in sys.argv:
        sys.exit(0 if tower.test_alert() else 1)
    tower.run(once="--once" in sys.argv)


if __name__ == "__main__":
    main()
