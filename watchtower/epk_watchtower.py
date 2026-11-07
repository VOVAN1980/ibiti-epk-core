# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Volodymyr Podkorytov (IBITI Labs). See LICENSE-BUSL-1.1.
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

Usage:
    python watchtower/epk_watchtower.py --config watchtower/config.bsc-testnet.json [--once] [--dry-run]

Needs Python 3.8+ (no packages) to watch, and Foundry's `cast` to sign the guardian's responses.
The guardian key is read from an environment variable or the local, git-ignored .env file and is
never printed or written anywhere.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone

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


def describe_call(data):
    """Human-readable description of the call an operation would make."""
    sel = data[:10].lower()
    if sel not in BY_SELECTOR:
        return f"unknown call {sel}"
    sig, what = BY_SELECTOR[sel]
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
        what = describe_call(op["data"])
        if op["id"] in expected:
            state["seen"][op["id"]] = "expected"
            acts.append(("alert", "info", f"expected change scheduled ({expected[op['id']]}): {what}; ready {when}"))
            return acts
        state["seen"][op["id"]] = "unexpected"
        state["unexpected"] = [t for t in state["unexpected"] if now - t < 3600] + [now]
        acts.append(("alert", "critical", f"UNEXPECTED change scheduled by {op['by']}: {what}; would take effect {when} "
                                          f"— cancelling {op['id']}"))
        acts.append(("cancel", op["id"]))
        if len(state["unexpected"]) >= policy.get("panicAfterUnexpectedPerHour", 3) and not state["panicked"]:
            acts.append(("panic", f"{len(state['unexpected'])} unexpected changes within an hour"))
    elif kind == "OperationExecuted":
        op_id = log["topics"][1].lower()
        if op_id in expected or state["seen"].get(op_id) == "expected":
            acts.append(("alert", "info", f"expected change executed ({expected.get(op_id, op_id)})"))
        else:
            acts.append(("alert", "critical", f"a change that was NOT approved got executed: {op_id}"))
            if not state["panicked"]:
                acts.append(("panic", "an unapproved change was executed"))
    elif kind == "OperationCancelled":
        acts.append(("alert", "info", f"change {log['topics'][1]} cancelled by 0x{log['topics'][2][-40:]}"))
    elif kind == "Paused":
        acts.append(("alert", "warning", f"vault PAUSED by 0x{log['topics'][1][-40:]}"))
    elif kind == "Unpaused":
        acts.append(("alert", "warning", "vault unpaused"))
    elif kind == "EpochBumped":
        acts.append(("alert", "warning", "all policies, sessions and pending changes revoked (epoch bumped)"))
    elif kind == "AdminChanged":
        acts.append(("alert", "critical", f"vault admin changed to 0x{log['topics'][2][-40:]}"))
    elif kind in ("GuardianSet", "DelaySet", "DestinationSet"):
        acts.append(("alert", "warning", f"vault setting changed: {kind}"))
    return acts


def after_failed_cancel(op_id, state):
    """A cancel that did not go through is itself an emergency."""
    if state["panicked"]:
        return [("alert", "critical", f"cancel of {op_id} failed; vault already panicked")]
    return [("alert", "critical", f"cancel of {op_id} FAILED — pressing panic"), ("panic", f"could not cancel {op_id}")]


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

    # -- alerts ----------------------------------------------------------------------------
    def alert(self, level, text):
        line = f"{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')} [{level.upper()}] {text}"
        print(line, flush=True)
        os.makedirs(os.path.dirname(self.log_file) or ".", exist_ok=True)
        with open(self.log_file, "a", encoding="utf-8") as f:
            f.write(line + "\n")
        a = self.cfg.get("alerts", {})
        token = read_secret(a.get("telegramTokenEnv", "TELEGRAM_BOT_TOKEN"), self.cfg.get("envFile", ".env"))
        chat = read_secret(a.get("telegramChatEnv", "TELEGRAM_CHAT_ID"), self.cfg.get("envFile", ".env"))
        if token and chat and level != "info":
            try:
                body = json.dumps({"chat_id": chat, "text": f"EPK Watchtower — vault {self.vault}\n{line}"}).encode()
                urllib.request.urlopen(urllib.request.Request(
                    f"https://api.telegram.org/bot{token}/sendMessage", body, {"Content-Type": "application/json"}), timeout=15)
            except OSError as e:
                print(f"  (telegram alert not sent: {type(e).__name__})", flush=True)

    # -- guardian responses -------------------------------------------------------------------
    def send(self, sig, *args):
        """Sign and send a guardian transaction with cast. Returns (tx hash, ok)."""
        if self.dry:
            self.alert("info", f"dry run: would send {sig} {' '.join(args)}")
            return None, True
        if not self.key:
            self.alert("critical", f"no guardian key ({self.cfg['guardianKeyEnv']}) — cannot send {sig}")
            return None, False
        out = subprocess.run(["cast", "send", self.vault, sig, *args, "--rpc-url", self.url, "--json",
                              "--private-key", self.key], capture_output=True, text=True)
        try:
            rc = json.loads(out.stdout)
            return rc.get("transactionHash"), int(rc.get("status", "0x0"), 16) == 1
        except (ValueError, TypeError):
            err = (out.stderr or "").strip().splitlines()
            self.alert("warning", f"{sig} not sent: {err[-1][:200] if err else 'no output'}")
            return None, False

    def act(self, actions):
        for a in actions:
            if a[0] == "alert":
                self.alert(a[1], a[2])
            elif a[0] == "cancel":
                tx, ok = self.send("cancel(bytes32)", a[1])
                self.state["actions"].append({"action": "cancel", "id": a[1], "tx": tx, "ok": ok})
                if ok:
                    self.alert("critical" if tx else "info",
                               f"STOPPED: unexpected change {a[1]} cancelled" + (f" — tx {tx}" if tx else ""))
                else:
                    self.act(after_failed_cancel(a[1], self.state))
            elif a[0] == "panic" and not self.state["panicked"]:
                tx, ok = self.send("panic()")
                self.state["panicked"] = ok
                self.state["actions"].append({"action": "panic", "reason": a[1], "tx": tx, "ok": ok})
                self.alert("critical", f"PANIC ({a[1]}): " + (f"tx {tx}" if ok else "FAILED — call the owner"))

    # -- main loop -------------------------------------------------------------------------------
    def poll(self):
        latest = int(rpc(self.url, "eth_blockNumber"), 16)
        start = self.state["lastBlock"] + 1 if self.state["lastBlock"] is not None else self.cfg.get("startBlock", latest)
        if start == "latest":
            start = latest
        while start <= latest:
            end = min(start + 4999, latest)
            logs = rpc(self.url, "eth_getLogs", {"address": self.vault, "fromBlock": hex(start), "toBlock": hex(end),
                                                 "topics": [list(EV.values())]})
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
        self.alert("info", f"watching vault {self.vault} on chain {cid}; guardian {guardian or 'none'} "
                           f"({'confirmed by the vault' if is_g else 'NOT a guardian of this vault'}); "
                           f"{len(self.expected)} approved change(s); {'DRY RUN' if self.dry else 'live'}")
        while True:
            try:
                self.poll()
            except (OSError, RuntimeError) as e:
                print(f"  (node error, retrying: {e})", flush=True)
            if once:
                return
            time.sleep(self.cfg.get("pollSeconds", 3))


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
    Watchtower(cfg, dry_run="--dry-run" in sys.argv).run(once="--once" in sys.argv)


if __name__ == "__main__":
    main()
