"""Independently re-check the EPK v2 testnet evidence against the chain.

Usage (from the repo root; Python 3.8+ only — no Foundry, no keys, no packages):
    python scripts/v2/verify_evidence.py [--rpc-url URL] [--build]

The claims live in deployments/bsc-testnet/epk-v2-evidence.json (and, for people, in
docs/TESTNET_V2.md — the script first checks that both list the same transactions and contracts).
A public BSC Testnet node is then asked:

  network       chainId must be 97;
  code          every contract has code; its keccak256 code hash is printed; for vault
                implementations the hash must equal the one pinned in EPKRegistry, and the
                demo vault's EIP-1967 slot must point to the claimed implementation;
                with --build (after `forge build`) the on-chain bytecode must also equal the
                bytecode compiled from this repository (immutable values masked);
  transactions  each tx exists, was sent by the claimed role to the claimed contract, and:
                - successful ones emitted the claimed events (emitter, indexed args, amounts);
                - rejected ones failed by revert (not out of gas), and the claimed custom error is
                  proven in the strongest way available, and the report says which one:
                    STRICT  execution trace of the original tx (live from --trace-rpc, or a trace saved
                            in deployments/bsc-testnet/traces/ whose from/to/input/gas match the tx);
                    REPLAY  eth_call of the same tx against the state right before its block, plus a
                            check that no earlier tx in that block was sent to the vault or the token
                            (a replay is not a trace: internal calls from other contracts in the same
                            block cannot be ruled out without one);
  checkpoints   historical state at fixed block numbers (paused, implementation, balance,
                limits left) — stays reproducible after later upgrades;
  now           the vault's current implementation, version, balance and pause state.

The default node (publicnode) keeps historical state, which checkpoints and replays need. Free
public nodes do not keep traces of old transactions; Binance's own node traces recent ones, so
right after an attack is sent, `--save-traces` stores its trace for later strict checks.
Exit code 0 = everything matches, 1 = a mismatch, 2 = something could not be checked.
"""
import json
import os
import re
import sys
import urllib.request
from datetime import datetime, timezone
from decimal import Decimal

RPC = "https://bsc-testnet-rpc.publicnode.com"
TRACE_RPC = "https://data-seed-prebsc-1-s1.binance.org:8545"  # traces recent transactions only
TRACES = "deployments/bsc-testnet/traces"
EVIDENCE = "deployments/bsc-testnet/epk-v2-evidence.json"
DOC = "docs/TESTNET_V2.md"
IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"  # EIP-1967

# ---------------------------------------------------------------------------------------------
# Keccak-256 in pure Python (Ethereum's hash), so the check needs no third-party packages.
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
assert keccak(b"transfer(address,uint256)")[:4].hex() == "a9059cbb"


def selector(sig):
    return "0x" + keccak(sig.encode())[:4].hex()


def topic0(sig):
    return "0x" + keccak(sig.encode()).hex()


# ---------------------------------------------------------------------------------------------
class RpcError(Exception):
    def __init__(self, err):
        super().__init__(err.get("message", str(err)))
        self.data = err.get("data")


class Chain:
    def __init__(self, url):
        self.url = url

    def __call__(self, method, *params):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)}).encode()
        req = urllib.request.Request(self.url, body, {"Content-Type": "application/json", "User-Agent": "epk-verify/2.0"})
        with urllib.request.urlopen(req, timeout=40) as r:
            out = json.load(r)
        if "error" in out:
            raise RpcError(out["error"])
        return out["result"]

    def call(self, to, data, block="latest"):
        return self("eth_call", {"to": to, "data": data}, block)


def w(v):
    """ABI word for an int or an address."""
    if isinstance(v, str):
        v = int(v, 16)
    return format(v, "064x")


def wei(amount):
    return int(Decimal(str(amount)) * 10 ** 18)


def eusd(v):
    return f"{Decimal(v) / Decimal(10 ** 18):,.4f}".rstrip("0").rstrip(".")


def no_history(e):
    m = str(e).lower()
    return any(k in m for k in ("missing trie node", "unknown state", "historical state", "pruned", "not available"))


class Report:
    def __init__(self):
        self.ok = self.bad = self.skip = 0

    def line(self, good, text):
        if good is None:
            self.skip += 1
            tag = "SKIP"
        elif good:
            self.ok += 1
            tag = "OK  "
        else:
            self.bad += 1
            tag = "BAD "
        print(f"  {tag} {text}")
        return good


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    url = sys.argv[sys.argv.index("--rpc-url") + 1] if "--rpc-url" in sys.argv else RPC
    trace_url = sys.argv[sys.argv.index("--trace-rpc") + 1] if "--trace-rpc" in sys.argv else TRACE_RPC
    build, save_traces = "--build" in sys.argv, "--save-traces" in sys.argv
    methods = {"STRICT": 0, "REPLAY": 0}
    ev = json.load(open(EVIDENCE, encoding="utf-8"))
    doc = open(DOC, encoding="utf-8").read()
    C = {k: v["address"] for k, v in ev["contracts"].items()}
    roles = ev["roles"]
    sessions = {k: int(v) for k, v in ev.get("sessions", {}).items()}
    names = {a.lower(): k for k, a in {**C, **roles}.items()}
    chain, tracer, rep = Chain(url), Chain(trace_url), Report()

    def show_error(sig, data):
        types = [] if sig.endswith("()") else sig[sig.index("(") + 1:-1].split(",")
        args = []
        for i, ty in enumerate(types):
            word = data[10 + 64 * i:74 + 64 * i] or "0"
            args.append(who("0x" + word[-40:]) if ty == "address" else
                        (f"{eusd(int(word, 16))} eUSD" if int(word, 16) >= 10 ** 15 else str(int(word, 16))))
        return sig.split("(")[0] + f"({', '.join(args)})"

    def resolve(ref):
        if ref.startswith("session:"):
            return sessions[ref[8:]]
        if ref.startswith("uint:"):
            return int(ref[5:])
        return C.get(ref) or roles[ref]

    def who(addr):
        return names.get(addr.lower(), addr)

    print(f"EPK v2 evidence check — node {url}")

    # ---- network ---------------------------------------------------------------------------
    print("\nNetwork")
    cid = int(chain("eth_chainId"), 16)
    if not rep.line(cid == ev["chainId"], f"chainId {cid} (expected {ev['chainId']}, BSC Testnet)"):
        print("\nRESULT: wrong network — stopping.")
        sys.exit(1)

    # ---- document and evidence file say the same thing ------------------------------------
    print("\nDocument vs evidence file")
    doc_txs = {h.lower() for h in re.findall(r"/tx/(0x[0-9a-fA-F]{64})", doc)}
    ev_txs = {t["tx"].lower() for t in ev["transactions"]}
    rep.line(doc_txs == ev_txs, f"{DOC} and {EVIDENCE} list the same {len(ev_txs)} transactions"
             + ("" if doc_txs == ev_txs else f" (only in doc: {len(doc_txs - ev_txs)}, only in file: {len(ev_txs - doc_txs)})"))
    doc_addrs = {a.lower() for a in re.findall(r"/address/(0x[0-9a-fA-F]{40})", doc)}
    rep.line(doc_addrs <= {a.lower() for a in C.values()}, "every contract linked in the document is in the evidence file")

    # ---- contracts and code hashes -------------------------------------------------------------
    print("\nContracts and bytecode")
    codehash = {}
    for key, c in ev["contracts"].items():
        code = chain("eth_getCode", c["address"], "latest")
        if not rep.line(len(code) > 2, f"{c['address']}  {c['label']}: has code ({(len(code) - 2) // 2:,} bytes)"):
            continue
        h = "0x" + keccak(bytes.fromhex(code[2:])).hex()
        codehash[key] = h
        if c.get("codeHash"):
            rep.line(h == c["codeHash"].lower(), f"code hash {h} = recorded {c['codeHash'][:12]}...")
        else:
            print(f"         code hash {h} (not recorded in the evidence file)")
        if c.get("pinnedInRegistry"):
            r = chain.call(C["registry"], selector("releases(address)") + w(c["address"]))[2:]
            version, active_at, revoked, pinned = int(r[0:64], 16), int(r[64:128], 16), int(r[128:192], 16), "0x" + r[192:256]
            rep.line(pinned == h and not revoked, f"registry pins this exact code hash (version {version}, revoked: {bool(revoked)})")
            when = datetime.fromtimestamp(active_at, timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
            print(f"         usable by vaults from {when}")
            vv = int(chain.call(c["address"], selector("vaultVersion()")), 16)
            rep.line(vv == c["vaultVersion"] == version, f"vaultVersion() = {vv} (claimed {c['vaultVersion']})")
        if c.get("proxyImplementation"):
            impl = "0x" + chain("eth_getStorageAt", c["address"], IMPL_SLOT, "latest")[-40:]
            want = C[c["proxyImplementation"]]
            rep.line(impl.lower() == want.lower(), f"EIP-1967 implementation slot -> {who(impl)} ({impl})")
        if build:
            try:
                art = json.load(open(c["artifact"], encoding="utf-8"))["deployedBytecode"]
            except FileNotFoundError:
                rep.line(None, f"no build artifact {c['artifact']} — run `forge build` first")
                continue
            local, onchain = bytearray.fromhex(art["object"][2:]), bytearray.fromhex(code[2:])
            for refs in art.get("immutableReferences", {}).values():
                for ref in refs:
                    for buf in (local, onchain):
                        buf[ref["start"]:ref["start"] + ref["length"]] = bytes(ref["length"])
            rep.line(local == onchain, f"bytecode equals this repository's build ({c['artifact']}, immutables masked)")

    # ---- transactions ----------------------------------------------------------------------------
    print("\nTransactions")
    for t in ev["transactions"]:
        tx = chain("eth_getTransactionByHash", t["tx"])
        rc = chain("eth_getTransactionReceipt", t["tx"])
        head = f"{t['step']:<3} {t['tx'][:12]}...  {t['what']}"
        if not tx or not rc:
            rep.line(False, f"{head}: not found on chain")
            continue
        block = int(rc["blockNumber"], 16)
        ts = int(chain("eth_getBlockByNumber", hex(block), False)["timestamp"], 16)
        when = datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        status = int(rc["status"], 16)
        print(f"  {head}\n         block {block}, {when}")
        rep.line(tx["from"].lower() == roles[t["from"]].lower() and (tx["to"] or "").lower() == C[t["to"]].lower(),
                 f"sent by {t['from']} ({tx['from']}) to {t['to']}")
        if t["expect"] == "success":
            rep.line(status == 1, "succeeded on-chain")
            for e in t.get("events", []):
                cands = [lg for lg in rc["logs"] if lg["address"].lower() == C[e["emitter"]].lower()
                         and lg["topics"][0] == topic0(e["event"])]
                for i, ref in enumerate(e.get("indexed", [])):
                    want = "0x" + w(resolve(ref))
                    cands = [lg for lg in cands if len(lg["topics"]) > i + 1 and lg["topics"][i + 1] == want]
                for i, amount in enumerate(e.get("data", [])):
                    cands = [lg for lg in cands if int(lg["data"][2 + 64 * i:66 + 64 * i] or "0", 16) == wei(amount)]
                if e.get("codehashOf"):
                    cands = [lg for lg in cands if "0x" + lg["data"][-64:] == codehash.get(e["codehashOf"])]
                extra = (f", amounts {' / '.join(e['data'])} eUSD" if e.get("data") else "") + \
                        (f", code hash = on-chain code of {e['codehashOf']}" if e.get("codehashOf") else "")
                rep.line(len(cands) == 1, f"event {e['event'].split('(')[0]} from {e['emitter']}{extra}")
        else:
            gas_used, gas_limit = int(rc["gasUsed"], 16), int(tx["gas"], 16)
            rep.line(status == 0 and gas_used < gas_limit,
                     f"rejected on-chain by revert, not out of gas (gas used {gas_used:,} of {gas_limit:,})")
            want = selector(t["error"])
            # 1) STRICT: the execution trace of the original transaction
            trace, source, path = None, "", f"{TRACES}/{t['tx'].lower()}.json"
            try:
                trace, source = tracer("debug_traceTransaction", t["tx"], {"tracer": "callTracer"}), f"live trace from {trace_url}"
                if save_traces and not os.path.exists(path):
                    os.makedirs(TRACES, exist_ok=True)
                    json.dump({"tx": t["tx"], "node": trace_url, "tracer": "callTracer",
                               "capturedAt": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"), "trace": trace},
                              open(path, "w", encoding="utf-8"), indent=2)
                    print(f"         trace saved to {path}")
            except (RpcError, OSError):
                if os.path.exists(path):
                    saved = json.load(open(path, encoding="utf-8"))
                    trace, source = saved["trace"], f"saved trace ({saved['node']}, {saved['capturedAt']})"
            if trace is not None:
                bound = (trace.get("from", "").lower() == tx["from"].lower() and trace.get("to", "").lower() == tx["to"].lower()
                         and trace.get("input", "").lower() == tx["input"].lower() and int(trace.get("gasUsed", "0x0"), 16) <= gas_used)
                out = trace.get("output", "") or ""
                ok_ = bound and out[:10] == want
                methods["STRICT"] += ok_
                rep.line(ok_, f"STRICT  {source}: this exact tx reverted with {show_error(t['error'], out)}"
                         + ("" if ok_ else f" — NO: trace {'is for another tx' if not bound else 'shows ' + (out[:10] or 'no revert data')}"))
                continue
            # 2) REPLAY: the same call against the state right before the block
            try:
                chain("eth_call", {"from": tx["from"], "to": tx["to"], "data": tx["input"], "gas": tx["gas"],
                                   "value": tx.get("value", "0x0")}, hex(block - 1))
                rep.line(False, "REPLAY  did NOT revert")
                continue
            except RpcError as err:
                data = err.data if isinstance(err.data, str) else ""
                if not data and no_history(err):
                    rep.line(None, f"REPLAY  needs historical state; this node has none ({err})")
                    continue
            same = data[:10] == want
            methods["REPLAY"] += same
            rep.line(same, f"REPLAY  against the state before block {block}: reverts with {show_error(t['error'], data)}"
                     + ("" if same else f" — NO: chain returned selector {data[:10] or 'none'}"))
            full = chain("eth_getBlockByNumber", hex(block), True)
            idx = int(rc["transactionIndex"], 16)
            touched = [x for x in full["transactions"][:idx] if (x.get("to") or "").lower() in (C["vault"].lower(), C["token"].lower())]
            rep.line(True if not touched else None,
                     f"REPLAY  no earlier tx in block {block} was sent to the vault or the token (this tx is #{idx} of {len(full['transactions'])})"
                     if not touched else f"REPLAY  {len(touched)} earlier tx(s) in block {block} touched the vault or token — replay is indicative only")

    # ---- historical checkpoints ----------------------------------------------------------------
    print("\nCheckpoints (historical state at fixed blocks)")
    v, tok = C["vault"], C["token"]
    for cp in ev["checkpoints"]:
        b = hex(cp["block"])
        print(f"  block {cp['block']}: {cp['label']}")
        try:
            if "paused" in cp:
                p = bool(int(chain.call(v, selector("paused()"), b), 16))
                rep.line(p == cp["paused"], f"paused = {p}")
            if "implementation" in cp:
                impl = "0x" + chain("eth_getStorageAt", v, IMPL_SLOT, b)[-40:]
                rep.line(impl.lower() == C[cp["implementation"]].lower(), f"implementation = {who(impl)}")
            if "eUSD" in cp:
                bal = int(chain.call(tok, selector("balanceOf(address)") + w(v), b), 16)
                rep.line(bal == wei(cp["eUSD"]), f"vault eUSD balance = {eusd(bal)}")
            if "vaultLimitLeft" in cp:
                left = int(chain.call(v, selector("availableToSpend(address)") + w(tok), b), 16)
                rep.line(left == wei(cp["vaultLimitLeft"]), f"vault limit left today = {eusd(left)} eUSD")
            if "sessionBudgetLeft" in cp:
                s = cp["sessionBudgetLeft"]
                left = int(chain.call(v, selector("budgetAvailable(uint256,address)") + w(sessions[s["session"]]) + w(tok), b), 16)
                rep.line(left == wei(s["value"]), f"agent session budget left = {eusd(left)} eUSD")
        except RpcError as err:
            if no_history(err):
                rep.line(None, f"this node has no historical state for block {cp['block']} — use --rpc-url with an archive node")
            else:
                raise

    # ---- money moved while the attacks ran ---------------------------------------------------
    if ev.get("attackWindows"):
        print("\nAttack windows (vault balance before the first and after the last attack)")
        for aw in ev["attackWindows"]:
            try:
                bal = [int(chain.call(tok, selector("balanceOf(address)") + w(v), hex(b)), 16) for b in (aw["fromBlock"], aw["toBlock"])]
                rep.line(bal[0] == bal[1], f"{aw['label']}: blocks {aw['fromBlock']}..{aw['toBlock']}, "
                                           f"{eusd(bal[0])} -> {eusd(bal[1])} eUSD, moved by attacks: {eusd(bal[0] - bal[1])}")
            except RpcError as err:
                rep.line(None, f"{aw['label']}: needs historical state ({err})")

    # ---- now ---------------------------------------------------------------------------------
    print("\nDemo vault now")
    impl = "0x" + chain("eth_getStorageAt", v, IMPL_SLOT, "latest")[-40:]
    print(f"  implementation {who(impl)} ({impl}), vaultVersion {int(chain.call(v, selector('vaultVersion()')), 16)}")
    print(f"  paused: {bool(int(chain.call(v, selector('paused()')), 16))}")
    print(f"  eUSD balance: {eusd(int(chain.call(tok, selector('balanceOf(address)') + w(v)), 16))}")

    print(f"\nRejection reasons proven by execution trace (STRICT): {methods['STRICT']}, "
          f"by historical replay (REPLAY): {methods['REPLAY']}")
    print(f"RESULT: {rep.ok} checks OK, {rep.bad} mismatches, {rep.skip} not checkable — "
          + ("everything matches the evidence" if rep.bad == rep.skip == 0 else
             "MISMATCH, see BAD lines" if rep.bad else "incomplete, see SKIP lines"))
    sys.exit(1 if rep.bad else 2 if rep.skip else 0)


if __name__ == "__main__":
    main()
