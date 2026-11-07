"""Independently re-check the EPK v2 testnet evidence against the chain.

Usage (from the repo root; needs only Python 3, no Foundry, no keys):
    python scripts/v2/verify_evidence.py [--rpc-url URL] [--doc docs/TESTNET_V2.md]

It reads every BscScan link in the evidence document and asks a public BSC Testnet RPC node:
  * every listed contract really has code on chain;
  * every listed transaction was mined, and its status matches the document
    (rows marked "rejected" must have failed on-chain, all others must have succeeded);
  * which implementation the demo vault currently runs, its eUSD balance and pause state.
Exit code 1 if anything does not match.
"""
import json
import re
import sys
import urllib.request
from datetime import datetime, timezone

RPC = "https://data-seed-prebsc-1-s1.binance.org:8545"
DOC = "docs/TESTNET_V2.md"
IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"  # EIP-1967


def arg(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def rpc(url, method, *params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)}).encode()
    req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "epk-verify/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.load(r)
    if "error" in out:
        raise RuntimeError(out["error"])
    return out["result"]


def main():
    sys.stdout.reconfigure(encoding="utf-8")  # Windows consoles
    url, doc = arg("--rpc-url", RPC), arg("--doc", DOC)
    text = open(doc, encoding="utf-8").read()
    ok = True

    chain = int(rpc(url, "eth_chainId"), 16)
    print(f"chainId {chain} {'(BSC Testnet)' if chain == 97 else '— NOT BSC Testnet'}")
    ok &= chain == 97

    print("\nContracts")
    contracts = list(dict.fromkeys(re.findall(r"\|\s*\**([^|]+?)\**\s*\|\s*\[0x[^\]]*\]\(https://testnet\.bscscan\.com/address/(0x[0-9a-fA-F]{40})", text)))
    for name, addr in contracts:
        has = rpc(url, "eth_getCode", addr, "latest") not in ("0x", "0x0")
        ok &= has
        print(f"  {'OK ' if has else 'BAD'} {addr}  {name.replace('*', '').strip()}  {'has code' if has else 'NO CODE'}")

    print("\nTransactions")
    for line in text.splitlines():
        m = re.search(r"testnet\.bscscan\.com/tx/(0x[0-9a-fA-F]{64})", line)
        if not m:
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        step, what, result = cells[0], cells[1], cells[-1]
        expect = 0 if "rejected" in result.lower() else 1
        rc = rpc(url, "eth_getTransactionReceipt", m.group(1))
        if rc is None:
            ok = False
            print(f"  BAD {step:<3} {m.group(1)[:12]}...  not found on chain")
            continue
        status, block = int(rc["status"], 16), int(rc["blockNumber"], 16)
        ts = int(rpc(url, "eth_getBlockByNumber", hex(block), False)["timestamp"], 16)
        when = datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        good = status == expect
        ok &= good
        label = "rejected on-chain" if status == 0 else "succeeded"
        print(f"  {'OK ' if good else 'BAD'} {step:<3} {m.group(1)[:12]}...  block {block}  {when}  {label:<17}  {what}")

    vault = re.search(r"Demo vault\*\*[^\n]*?/address/(0x[0-9a-fA-F]{40})", text)
    token = re.search(r"eUSD\)[^\n]*?/address/(0x[0-9a-fA-F]{40})", text)
    if vault:
        v = vault.group(1)
        impl = "0x" + rpc(url, "eth_getStorageAt", v, IMPL_SLOT, "latest")[-40:]
        names = {a.lower(): n.replace('*', '').strip() for n, a in contracts}
        print(f"\nDemo vault {v}")
        print(f"  runs implementation {impl}  ({names.get(impl.lower(), 'unknown')})")
        paused = int(rpc(url, "eth_call", {"to": v, "data": "0x5c975abb"}, "latest"), 16)  # paused()
        print(f"  paused: {bool(paused)}")
        if token:
            bal = int(rpc(url, "eth_call", {"to": token.group(1), "data": "0x70a08231" + v[2:].lower().rjust(64, "0")}, "latest"), 16)
            print(f"  eUSD balance: {bal / 1e18:,.2f}")

    print("\nRESULT:", "everything matches the document" if ok else "MISMATCH — see BAD lines above")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
