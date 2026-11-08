# SPDX-License-Identifier: BUSL-1.1
"""Independently re-check the EPK v2 testnet evidence against the chain.

Usage (from the repo root; Python 3.8+ only — no Foundry, no keys, no packages):
    python scripts/v2/verify_evidence.py [--rpc-url URL[,URL...]] [--build]
    python scripts/v2/verify_evidence.py --evidence deployments/bsc-testnet/epk-v2.1-evidence.json --doc docs/TESTNET_V21.md

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

Free public nodes forget old history, each in its own way, so the script asks several of them
(NODES, or your own list with --rpc-url A,B): every request goes to the first node, and the next one
is asked only when a node has no answer — a transaction it no longer returns, state it has pruned, a
request it refuses, or no response. A revert is an answer and is never retried elsewhere. Event logs
are taken from one node only, and only if they contain every event of the evidence transactions
(a node that pruned old logs returns an empty list instead of an error). What no node can answer is
reported as OLD (history no node asked still keeps), never as passed and never as a mismatch.
No free node keeps traces of old transactions; Binance's own node traces recent ones, so
right after an attack is sent, `--save-traces` stores its trace for later strict checks.
Exit code 0 = everything matches, 1 = a mismatch, 2 = something could not be checked.
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from decimal import Decimal
from urllib.parse import urlparse

# Free public BSC Testnet nodes, asked in this order (tested 2026-11-08; all allow browser requests):
NODES = [
    "https://bsc-testnet.bnbchain.org",        # BNB Chain's own node: every transaction, but only the latest state, no logs
    "https://97.rpc.thirdweb.com",             # keeps old state and event logs (archive); strict rate limit, so asked second
    "https://bsc-testnet-rpc.publicnode.com",  # state of the last hour or so; drops transactions after about a day
]
TRACE_RPC = "https://data-seed-prebsc-1-s1.binance.org:8545"  # traces recent transactions only
TRACES = "deployments/bsc-testnet/traces"
ARCHIVE_DIR = "deployments/bsc-testnet/verification"
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


def host(url):
    return urlparse(url).netloc or url


def reverted(err):
    """A node's error that is a real answer: the call reverted (with or without revert data)."""
    if not isinstance(err, dict):
        return False
    data = err.get("data")
    return (isinstance(data, str) and data.startswith("0x")) or "revert" in str(err.get("message", "")).lower()


class Chain:
    """JSON-RPC over a list of nodes, asked in order (see NODES)."""
    LOOKUPS = ("eth_getTransactionByHash", "eth_getTransactionReceipt", "eth_getBlockByNumber")

    def __init__(self, urls, record=None, used=None, silent=None):
        self.urls, self.record = list(urls), record  # record: list collecting raw node answers (--archive)
        self.used = used if used is not None else {u: 0 for u in self.urls}  # answers per node
        self.silent = silent if silent is not None else {}  # requests a node never answered (after retries)
        self.last = None  # the node that gave the last answer

    def only(self, url):
        return Chain([url], self.record, self.used, self.silent)

    def _post(self, url, method, params):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)}).encode()
        attempt = 0
        while True:  # a busy node (rate limit, 5xx) is asked again 1, 2, 4, 8, 8 s later; a silent one once more
            req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "epk-verify/2.0"})
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    return json.load(r)
            except urllib.error.HTTPError as e:
                try:
                    out = json.loads(e.read())
                except ValueError:
                    out = None
                if isinstance(out, dict) and "error" in out and e.code != 429 and e.code < 500:
                    return out  # some nodes send their JSON-RPC errors with HTTP 4xx
                why, tries = f"HTTP {e.code}", 6
            except (OSError, ValueError) as e:
                why, tries = str(e), 2
            attempt += 1
            if attempt >= tries:
                break
            time.sleep(min(2 ** (attempt - 1), 8))
        self.silent[url] = self.silent.get(url, 0) + 1
        return {"error": {"message": f"no response ({why})"}}

    def __call__(self, method, *params):
        errors = []
        for url in self.urls:
            if self.silent.get(url, 0) >= 3:  # a node that stopped answering is not asked again in this run
                errors.append(f"{host(url)}: not answering")
                continue
            out = self._post(url, method, params)
            if self.record is not None:
                self.record.append({"node": url, "method": method, "params": list(params),
                                    **({"error": out["error"]} if "error" in out else {"result": out.get("result")})})
            err = out.get("error")
            if err is None and out.get("result") is None and method in self.LOOKUPS:
                errors.append(f"{host(url)}: not found")
                continue
            if err is None or reverted(err):
                self.used[url] = self.used.get(url, 0) + 1
                self.last = url
                if err:
                    raise RpcError(err)
                return out.get("result")
            errors.append(f"{host(url)}: {err.get('message', err) if isinstance(err, dict) else err}")
        if method in self.LOOKUPS:
            return None  # no node asked still returns it
        raise RpcError({"message": "; ".join(errors)})

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
    return any(k in m for k in ("missing trie node", "unknown state", "historical state", "pruned", "not available",
                                "header not found"))


class History:
    """Vault facts derived from event logs, for when no node keeps the old state. All logs come from one
    node, which is used only if its logs contain every vault/token event of the evidence transactions:
    a node that pruned old logs answers with an empty list, which would otherwise look like a real answer."""

    STEP = 1_000  # blocks per eth_getLogs request (the most some free nodes accept)
    TRANSFER = topic0("Transfer(address,address,uint256)")

    def __init__(self, chain, vault, token, start, end, receipts):
        self.chain, self.vault, self.token = chain, vault.lower(), token.lower()
        self.start, self.end, self.receipts = start, end, receipts
        self.loaded, self.node, self.notes = False, None, []

    def _logs(self, chain, flt):
        out, b = [], self.start
        while b <= self.end:
            e = min(b + self.STEP - 1, self.end)
            out += chain("eth_getLogs", {**flt, "fromBlock": hex(b), "toBlock": hex(e)})
            b = e + 1
        return out

    def _ours(self, lg):
        """Every event of the vault, and every Transfer of the token."""
        a = lg["address"].lower()
        return a == self.vault or (a == self.token and lg["topics"][:1] == [self.TRANSFER])

    def load(self):
        """Returns self if some node's logs are complete, else None (values cannot be derived: OLD)."""
        if not self.loaded:
            self.loaded = True
            key = lambda lg: (lg["transactionHash"].lower(), int(lg["logIndex"], 16))  # noqa: E731
            want = {key(lg) for rc in self.receipts if self.start <= int(rc["blockNumber"], 16) <= self.end
                    for lg in rc["logs"] if self._ours(lg)}
            for url in self.chain.urls:
                one = self.chain.only(url)
                try:
                    logs = self._logs(one, {"address": self.vault}) + \
                        self._logs(one, {"address": self.token, "topics": [self.TRANSFER]})
                except RpcError as err:
                    self.notes.append(str(err)[:120])
                    continue
                got = {key(lg) for lg in logs}
                if not want:
                    self.notes.append(f"{host(url)}: no evidence transaction in these blocks to cross-check its logs with")
                    continue
                if not want <= got:
                    self.notes.append(f"{host(url)}: its logs miss {len(want - got)} of the {len(want)} events of the evidence transactions")
                    continue
                logs.sort(key=lambda lg: (int(lg["blockNumber"], 16), int(lg["logIndex"], 16)))
                t = lambda lg, i: lg["topics"][i] if len(lg["topics"]) > i else None  # noqa: E731
                of_vault = [lg for lg in logs if lg["address"].lower() == self.vault]
                transfers = [lg for lg in logs if lg["address"].lower() == self.token and t(lg, 0) == self.TRANSFER]
                vw = "0x" + w(self.vault)
                self.t_in = [lg for lg in transfers if t(lg, 2) == vw]
                self.t_out = [lg for lg in transfers if t(lg, 1) == vw]
                self.pause = [lg for lg in of_vault if t(lg, 0) in (topic0("Paused(address)"), topic0("Unpaused()"))]
                self.upgraded = [lg for lg in of_vault if t(lg, 0) == topic0("Upgraded(address)")]
                self.outflow = [lg for lg in of_vault if t(lg, 0) == topic0("Outflow(address,uint256,uint256)")
                                and t(lg, 1) == "0x" + w(self.token)]
                self.node = url
                break
        return self if self.node else None

    @staticmethod
    def _upto(logs, n, after=-1):
        return [lg for lg in logs if after < int(lg["blockNumber"], 16) <= n]

    def paused(self, n):
        ev = self._upto(self.pause, n)
        return bool(ev) and ev[-1]["topics"][0] == topic0("Paused(address)")

    def implementation(self, n):
        ev = self._upto(self.upgraded, n)
        return ("0x" + ev[-1]["topics"][1][-40:]) if ev else None

    def balance(self, n):
        return sum(int(lg["data"], 16) for lg in self._upto(self.t_in, n)) - sum(int(lg["data"], 16) for lg in self._upto(self.t_out, n))

    def moved_out(self, a, b):
        return sum(int(lg["data"], 16) for lg in self._upto(self.t_out, b, after=a))

    def limit_left(self, n):
        ev = [lg for lg in self.outflow if int(lg["blockNumber"], 16) == n]
        return int(ev[-1]["data"][66:130], 16) if ev else None  # Outflow.availableAfter, only at a payment block


class Report:
    def __init__(self):
        self.ok = self.bad = self.skip = self.pruned = 0

    def line(self, good, text, pruned=False):
        if good is None and pruned:
            self.pruned += 1
            tag = "OLD "
        elif good is None:
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
    urls = [u.strip() for u in sys.argv[sys.argv.index("--rpc-url") + 1].split(",") if u.strip()] if "--rpc-url" in sys.argv else NODES
    trace_url = sys.argv[sys.argv.index("--trace-rpc") + 1] if "--trace-rpc" in sys.argv else TRACE_RPC
    build, save_traces = "--build" in sys.argv, "--save-traces" in sys.argv
    methods = {"STRICT": 0, "REPLAY": 0}
    # --evidence / --doc check another claims file the same way (e.g. the EPK 2.1 guard demo)
    global EVIDENCE, DOC
    EVIDENCE = sys.argv[sys.argv.index("--evidence") + 1] if "--evidence" in sys.argv else EVIDENCE
    DOC = sys.argv[sys.argv.index("--doc") + 1] if "--doc" in sys.argv else DOC
    ev = json.load(open(EVIDENCE, encoding="utf-8"))
    doc = open(DOC, encoding="utf-8").read()
    sym = ev.get("tokenSymbol", "eUSD")
    C = {k: v["address"] for k, v in ev["contracts"].items()}
    roles = ev["roles"]
    sessions = {k: int(v) for k, v in ev.get("sessions", {}).items()}
    names = {a.lower(): k for k, a in {**C, **roles}.items()}
    archive = sys.argv[sys.argv.index("--archive") + 1] if "--archive" in sys.argv else None
    record = [] if archive else None
    chain, tracer, rep = Chain(urls, record), Chain([trace_url], record), Report()

    def show_error(sig, data):
        types = [] if sig.endswith("()") else sig[sig.index("(") + 1:-1].split(",")
        args = []
        for i, ty in enumerate(types):
            word = data[10 + 64 * i:74 + 64 * i] or "0"
            args.append(who("0x" + word[-40:]) if ty == "address" else
                        (f"{eusd(int(word, 16))} {sym}" if int(word, 16) >= 10 ** 15 else str(int(word, 16))))
        return sig.split("(")[0] + f"({', '.join(args)})"

    def resolve(ref):
        if ref.startswith("0x"):
            return ref  # a raw 32-byte value, e.g. an operation id
        if ref.startswith("session:"):
            return sessions[ref[8:]]
        if ref.startswith("uint:"):
            return int(ref[5:])
        return C.get(ref) or roles[ref]

    def who(addr):
        return names.get(addr.lower(), addr)

    print("EPK v2 evidence check — nodes, asked in this order (the next one only when a node has no answer):")
    for i, u in enumerate(urls, 1):
        print(f"  {i}. {u}")

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
        if build and c.get("artifact"):
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
    receipts = []
    for t in ev["transactions"]:
        tx = chain("eth_getTransactionByHash", t["tx"])
        rc = chain("eth_getTransactionReceipt", t["tx"])
        head = f"{t['step']:<3} {t['tx'][:12]}...  {t['what']}"
        if not tx or not rc:
            rep.line(None, f"{head}: no node asked still returns this transaction (public nodes drop old ones) — "
                           f"check it on testnet.bscscan.com or put an archive node first (--rpc-url)", pruned=True)
            continue
        receipts.append(rc)
        found_on = chain.last
        block = int(rc["blockNumber"], 16)
        ts = int(chain("eth_getBlockByNumber", hex(block), False)["timestamp"], 16)
        when = datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        status = int(rc["status"], 16)
        print(f"  {head}\n         block {block}, {when}" + ("" if found_on == urls[0] else f" (from {host(found_on)})"))
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
                extra = (f", amounts {' / '.join(e['data'])} {e.get('unit', sym)}" if e.get("data") else "") + \
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
                    rep.line(None, f"REPLAY  no node asked still keeps the state of block {block - 1}: re-check the reason "
                                   f"with an archive node (--rpc-url); earlier replays are archived in {ARCHIVE_DIR}/",
                             pruned=True)
                    continue
                if not data and not reverted({"message": str(err)}):
                    rep.line(None, f"REPLAY  no node could replay it ({str(err)[:160]})")
                    continue
            same = data[:10] == want
            methods["REPLAY"] += same
            rep.line(same, f"REPLAY  against the state before block {block}: reverts with {show_error(t['error'], data)}"
                     + ("" if same else f" — NO: chain returned selector {data[:10] or 'none'}")
                     + ("" if chain.last == urls[0] else f" (state from {host(chain.last)})"))
            full = chain("eth_getBlockByNumber", hex(block), True)
            idx = int(rc["transactionIndex"], 16)
            touched = [x for x in full["transactions"][:idx] if (x.get("to") or "").lower() in (C["vault"].lower(), C["token"].lower())]
            rep.line(True if not touched else None,
                     f"REPLAY  no earlier tx in block {block} was sent to the vault or the token (this tx is #{idx} of {len(full['transactions'])})"
                     if not touched else f"REPLAY  {len(touched)} earlier tx(s) in block {block} touched the vault or token — replay is indicative only")

    # ---- historical checkpoints ----------------------------------------------------------------
    print("\nCheckpoints — the vault at fixed blocks")
    print("  STATE  = historical state read from a node (most free nodes keep it only for recent blocks)")
    print("  EVENTS = derived from event logs, when no node asked keeps the state")
    v, tok = C["vault"], C["token"]
    last_block = max([cp["block"] for cp in ev["checkpoints"]] + [aw["toBlock"] for aw in ev.get("attackWindows", [])] or [0])
    hist = History(chain, v, tok, ev["contracts"]["vault"]["createdAtBlock"], last_block, receipts)

    def events():
        first = not hist.loaded
        h = hist.load()
        if first:
            for note in hist.notes:
                print(f"         event logs not used from {note}")
            print(f"         event logs from {host(h.node)}" if h else "         no node asked has complete event logs")
        return h

    def at(n, state_fn, event_fn):
        try:
            val = state_fn(hex(n))
            return val, "STATE " if chain.last == urls[0] else f"STATE ({host(chain.last)})"
        except RpcError as err:
            if not no_history(err):
                raise
        h = events() if event_fn else None
        val = event_fn(h, n) if h else None
        return (val, "EVENTS") if val is not None else (None, None)

    def check(n, label, state_fn, event_fn, expect, show):
        val, how = at(n, state_fn, event_fn)
        if how is None:
            rep.line(None, f"{label}: no node asked still keeps block {n}'s state and it cannot be derived from "
                           f"events — re-check with an archive node (--rpc-url); archived in {ARCHIVE_DIR}/", pruned=True)
        else:
            rep.line(val == expect, f"{how} {label} = {show(val)}")

    for cp in ev["checkpoints"]:
        n = cp["block"]
        print(f"  block {n}: {cp['label']}")
        if "paused" in cp:
            check(n, "paused", lambda b: bool(int(chain.call(v, selector("paused()"), b), 16)),
                  lambda h, n: h.paused(n), cp["paused"], str)
        if "implementation" in cp:
            check(n, "implementation", lambda b: ("0x" + chain("eth_getStorageAt", v, IMPL_SLOT, b)[-40:]).lower(),
                  lambda h, n: (h.implementation(n) or "").lower() or None, C[cp["implementation"]].lower(), who)
        if "eUSD" in cp:
            check(n, "vault eUSD balance", lambda b: int(chain.call(tok, selector("balanceOf(address)") + w(v), b), 16),
                  lambda h, n: h.balance(n), wei(cp["eUSD"]), eusd)
        if "vaultLimitLeft" in cp:
            check(n, "vault limit left today (eUSD)", lambda b: int(chain.call(v, selector("availableToSpend(address)") + w(tok), b), 16),
                  lambda h, n: h.limit_left(n), wei(cp["vaultLimitLeft"]), eusd)
        if "sessionBudgetLeft" in cp:
            s = cp["sessionBudgetLeft"]
            check(n, "agent session budget left (eUSD)",
                  lambda b: int(chain.call(v, selector("budgetAvailable(uint256,address)") + w(sessions[s["session"]]) + w(tok), b), 16),
                  None, wei(s["value"]), eusd)

    # ---- money moved while the attacks ran ---------------------------------------------------
    if ev.get("attackWindows"):
        print("\nAttack windows (vault balance before the first and after the last attack)")
        for aw in ev["attackWindows"]:
            a, b = aw["fromBlock"], aw["toBlock"]
            try:
                bal = [int(chain.call(tok, selector("balanceOf(address)") + w(v), hex(x)), 16) for x in (a, b)]
                how, moved = "STATE " if chain.last == urls[0] else f"STATE ({host(chain.last)})", bal[0] - bal[1]
            except RpcError as err:
                if not no_history(err):
                    raise
                h = events()
                if not h:
                    rep.line(None, f"{aw['label']}: no node asked still keeps the state of blocks {a}..{b} and it cannot be "
                                   f"derived from events — re-check with an archive node (--rpc-url)", pruned=True)
                    continue
                bal, how, moved = [h.balance(a), h.balance(b)], "EVENTS", h.moved_out(a, b)
            rep.line(bal[0] == bal[1] and moved == 0, f"{how} {aw['label']}: blocks {a}..{b}, "
                                                      f"{eusd(bal[0])} -> {eusd(bal[1])} {sym}, moved out: {eusd(moved)}")

    # ---- now ---------------------------------------------------------------------------------
    print("\nDemo vault now")
    impl = "0x" + chain("eth_getStorageAt", v, IMPL_SLOT, "latest")[-40:]
    print(f"  implementation {who(impl)} ({impl}), vaultVersion {int(chain.call(v, selector('vaultVersion()')), 16)}")
    print(f"  paused: {bool(int(chain.call(v, selector('paused()')), 16))}")
    print(f"  {sym} balance: {eusd(int(chain.call(tok, selector('balanceOf(address)') + w(v)), 16))}")

    print(f"\nRejection reasons proven by execution trace (STRICT): {methods['STRICT']}, "
          f"by historical replay (REPLAY): {methods['REPLAY']}")
    print("Answers per node: " + ", ".join(f"{host(u)} {chain.used.get(u, 0)}" for u in urls))
    print(f"RESULT: {rep.ok} checks OK, {rep.bad} mismatches, {rep.skip} not checkable, "
          f"{rep.pruned} need an archive node (OLD: history no node asked still keeps) — "
          + ("everything checkable matches the evidence" if rep.bad == rep.skip == 0 else
             "MISMATCH, see BAD lines" if rep.bad else "incomplete, see SKIP lines"))
    if archive:
        os.makedirs(os.path.dirname(archive) or ".", exist_ok=True)
        json.dump({"about": "Raw JSON-RPC answers used by verify_evidence.py, kept in case public nodes drop BSC "
                            "Testnet history. A snapshot for reference, not a substitute for re-checking.",
                   "capturedAt": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
                   "result": {"ok": rep.ok, "bad": rep.bad, "skip": rep.skip, "needArchiveNode": rep.pruned}, "calls": record},
                  open(archive, "w", encoding="utf-8"), indent=1)
        print(f"raw node answers archived: {archive} ({len(record)} calls)")
    sys.exit(1 if rep.bad else 2 if rep.skip else 0)


if __name__ == "__main__":
    main()
