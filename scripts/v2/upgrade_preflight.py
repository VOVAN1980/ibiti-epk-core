# SPDX-License-Identifier: BUSL-1.1
"""Checks before and after each step of the demo vault's upgrade to 2.0.1. It never signs anything.

Usage (from the repo root; Python 3 only, no keys):
    python scripts/v2/upgrade_preflight.py schedule   # day 7  (from 2026-11-14 12:04 UTC)
    python scripts/v2/upgrade_preflight.py execute    # day 9  (2 days after scheduling)
    python scripts/v2/upgrade_preflight.py after      # right after the upgrade
    (--rpc-url URL and --out DIR for a rehearsal on a local fork)

All timing decisions use block timestamps, not the computer's clock. Each mode prints READY or
NOT READY and, when ready, the one command that a person with the admin key runs after confirming.
`schedule` saves a snapshot of every public vault setting; `execute` and `after` compare against it:
the upgrade must not change any setting, balance or the vault's address.
Exit code 0 = ready / all good, 1 = not ready or a mismatch.
"""
import json
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from verify_evidence import IMPL_SLOT, RPC, Chain, RpcError, eusd, keccak, selector, topic0, w  # noqa: E402

EVIDENCE = "deployments/bsc-testnet/epk-v2-evidence.json"
OUT = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else "deployments/bsc-testnet/upgrade"
SALT = "0x" + keccak(b"EPK demo: upgrade to 2.0.1").hex()  # same salt as scripts/v2/DemoUpgrade.s.sol
GRACE = 14 * 24 * 3600
CMD = 'forge script scripts/v2/DemoUpgrade.s.sol:DemoUpgrade --sig "{}()" --rpc-url $BSC_RPC_URL --broadcast --slow'


def utc(ts):
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


def error_name(data):
    """Name of a vault/registry custom error, from the local build if there is one (`forge build`)."""
    data = data if isinstance(data, str) else ""
    for art in ("out/EPKVault.sol/EPKVault.json", "out/EPKRegistry.sol/EPKRegistry.json"):
        try:
            for e in json.load(open(art, encoding="utf-8"))["abi"]:
                if e["type"] == "error":
                    sig = f"{e['name']}({','.join(i['type'] for i in e['inputs'])})"
                    if data[:10] == selector(sig):
                        return sig
        except (OSError, KeyError, ValueError):
            pass
    return data[:10] or "no data"


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode not in ("schedule", "execute", "after"):
        sys.exit(__doc__)
    ev = json.load(open(EVIDENCE, encoding="utf-8"))
    C = {k: v["address"] for k, v in ev["contracts"].items()}
    roles, sessions = ev["roles"], {k: int(v) for k, v in ev["sessions"].items()}
    vault, tok, reg, rel, old = C["vault"], C["token"], C["registry"], C["release_2_0_1"], C["implementation_2_0_0"]
    chain = Chain(sys.argv[sys.argv.index("--rpc-url") + 1] if "--rpc-url" in sys.argv else RPC)
    bad = []

    def ok(cond, text):
        print(f"  {'OK ' if cond else 'NO '} {text}")
        if not cond:
            bad.append(text)
        return cond

    def call(to, sig, *args, frm=None):
        data = selector(sig) + "".join(w(a) for a in args)
        return chain("eth_call", {"to": to, "data": data, **({"from": frm} if frm else {})}, "latest")

    def settings():
        """Raw answers of every public vault setting that an upgrade must leave untouched."""
        g1, g2, adm = roles["guardian1"], roles["guardian2"], roles["admin"]
        q = {
            "admin()": [], "recovery()": [], "guardianCount()": [], "coSigner()": [], "registry()": [],
            "delay()": [], "paused()": [], "setupDone()": [], "epoch()": [], "nextPolicyId()": [],
            "sessionManager()": [], "nextSessionId()": [], "trackedAssets()": [],
            "isGuardian(address)": [[g1], [g2]], "isDestination(address)": [[adm]],
            "assets(address)": [[tok], [0]], "envelopes(uint256)": [[1]],
            "envelopeBudgetCap(uint256,address)": [[1, tok]],
            "policies(uint256)": [[s] for s in sessions.values()],
            "nonces(uint256)": [[s] for s in sessions.values()],
            "policyBudgets(uint256,address)": [[s, tok] for s in sessions.values()],
        }
        snap = {}
        for sig, arglists in q.items():
            for args in (arglists or [[]]):
                key = sig if not args else f"{sig}{args}"
                snap[key] = call(vault, sig, *args)
        snap["eUSD balanceOf(vault)"] = call(tok, "balanceOf(address)", vault)
        snap["native balance"] = chain("eth_getBalance", vault, "latest")
        snap["vault proxy code hash"] = "0x" + keccak(bytes.fromhex(chain("eth_getCode", vault, "latest")[2:])).hex()
        return snap

    now_block = chain("eth_getBlockByNumber", "latest", False)
    now = int(now_block["timestamp"], 16)
    print(f"Upgrade preflight: {mode} — chain time {utc(now)} (block {int(now_block['number'], 16)})\n")
    ok(int(chain("eth_chainId"), 16) == 97, "network is BSC Testnet (chainId 97)")

    # the release itself
    r = call(reg, "releases(address)", rel)[2:]
    version, active_at, revoked, pinned = int(r[0:64], 16), int(r[64:128], 16), int(r[128:192], 16), "0x" + r[192:256]
    code_hash = "0x" + keccak(bytes.fromhex(chain("eth_getCode", rel, "latest")[2:])).hex()
    want_hash = ev["contracts"]["release_2_0_1"]["codeHash"]
    ok(code_hash == pinned == want_hash, f"release 2.0.1 code hash {code_hash[:14]}… = registry pin = evidence file")
    ok(not revoked and version == 20001, f"release listed as version {version}, not revoked")
    impl = "0x" + chain("eth_getStorageAt", vault, IMPL_SLOT, "latest")[-40:]
    op = call(vault, "upgradeOperationData(address)", rel)
    op_bytes = bytes.fromhex(op[2:])[64:]  # decode `bytes` return value
    op_len = int.from_bytes(bytes.fromhex(op[2:])[32:64], "big")

    if mode in ("schedule", "execute"):
        ok(impl.lower() == old.lower(), f"vault {vault} still runs 2.0.0")
        ok(int(call(vault, "paused()"), 16) == 0, "vault is not paused")

    if mode == "schedule":
        ok(now >= active_at, f"release window over: usable from {utc(active_at)} by block time"
           + ("" if now >= active_at else f" — {active_at - now} s to go"))
        ok(int(call(reg, "isApproved(address)", rel), 16) == 1, "registry.isApproved(release) = true")
        try:
            chain("eth_call", {"from": roles["admin"], "to": vault,
                               "data": selector("scheduleUpgrade(address,bytes32)") + w(rel) + w(int(SALT, 16))}, "latest")
            ok(True, "dry run: scheduleUpgrade(release, salt) from the admin would succeed")
        except RpcError as e:
            ok(False, f"dry run: scheduleUpgrade would revert with {error_name(e.data)}")
        snap = settings()
        print(f"  ..  read {len(snap)} vault settings; balance {eusd(int(snap['eUSD balanceOf(vault)'], 16))} eUSD")
        if not bad:  # the reference snapshot is taken only on the real scheduling run
            os.makedirs(OUT, exist_ok=True)
            json.dump({"capturedAt": utc(now), "block": int(now_block["number"], 16), "settings": snap},
                      open(f"{OUT}/settings-before.json", "w", encoding="utf-8"), indent=1)
            print(f"  ..  saved them to {OUT}/settings-before.json for the execute/after checks")
        step = "schedule"

    if mode in ("execute", "after"):
        before = json.load(open(f"{OUT}/settings-before.json", encoding="utf-8"))["settings"]

    if mode == "execute":
        logs = chain("eth_getLogs", {"address": vault, "fromBlock": hex(ev["contracts"]["vault"]["createdAtBlock"]),
                                     "toBlock": "latest",
                                     "topics": [topic0("OperationScheduled(bytes32,bytes,bytes32,uint64,address)")]})
        mine = [lg for lg in logs if lg["data"][2 + 64:2 + 128] == SALT[2:]]
        if ok(len(mine) == 1, "the upgrade was scheduled exactly once (OperationScheduled with this salt)"):
            ready_at = int(mine[0]["data"][2 + 128:2 + 192], 16)
            ok(ready_at <= now <= ready_at + GRACE, f"timelock: executable from {utc(ready_at)} until {utc(ready_at + GRACE)}"
               + ("" if now >= ready_at else f" — {ready_at - now} s to go"))
        now_snap = settings()
        diff = [k for k in before if before[k] != now_snap.get(k)]
        ok(not diff, f"all {len(before)} vault settings unchanged since scheduling" + (f" — changed: {diff}" if diff else ""))
        try:
            data = selector("executeScheduled(bytes,bytes32)") + w(64) + w(int(SALT, 16)) + w(op_len) + op_bytes[:op_len].hex().ljust(((op_len + 31) // 32) * 64, "0")
            chain("eth_call", {"from": roles["admin"], "to": vault, "data": data}, "latest")
            ok(True, "dry run: executeScheduled(upgrade, salt) from the admin would succeed")
        except RpcError as e:
            ok(False, f"dry run: executeScheduled would revert with {error_name(e.data)}")
        step = "execute"

    if mode == "after":
        ok(impl.lower() == rel.lower(), f"vault {vault} now runs release 2.0.1 ({impl})")
        ok(int(call(vault, "vaultVersion()"), 16) == 20001, "vaultVersion() through the vault = 20001")
        after = settings()
        diff = [k for k in before if before[k] != after.get(k)]
        ok(not diff, f"all {len(before)} settings, both balances and the vault's own code identical to before the upgrade"
           + (f" — changed: {diff}" if diff else ""))
        print(f"  ..  vault balance {eusd(int(after['eUSD balanceOf(vault)'], 16))} eUSD, same address {vault}")
        json.dump({"capturedAt": utc(now), "block": int(now_block["number"], 16), "settings": after},
                  open(f"{OUT}/settings-after.json", "w", encoding="utf-8"), indent=1)
        step = None

    print()
    if bad:
        print(f"NOT READY — {len(bad)} check(s) failed. Do not sign anything.")
        sys.exit(1)
    if step:
        print("READY. After the owner confirms, the admin key signs exactly this (and nothing else):")
        print("  " + CMD.format(step))
    else:
        print("UPGRADE VERIFIED: same address, new version, every setting and balance unchanged.")


if __name__ == "__main__":
    main()
