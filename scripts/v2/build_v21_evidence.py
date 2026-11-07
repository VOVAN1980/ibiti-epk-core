# SPDX-License-Identifier: BUSL-1.1
"""Write deployments/bsc-testnet/epk-v2.1-evidence.json — the machine-readable claims of the EPK 2.1 guard
demo on BSC Testnet — from the deployment / run files and the mined receipts.

Every claim is then re-checked against the chain by:
    python scripts/v2/verify_evidence.py --evidence deployments/bsc-testnet/epk-v2.1-evidence.json --doc docs/TESTNET_V21.md

Amounts recorded here are read from the receipts (exact, 18 decimals); the expected revert reason of every
attack comes from the attack plan, and the verifier proves it from the execution trace (STRICT) or a replay.
"""
import json
import sys
import urllib.request
from decimal import Decimal

sys.path.insert(0, "scripts/v2")
from verify_evidence import keccak, selector, topic0  # noqa: E402  (pure-Python keccak, no packages)

RPC = "https://bsc-testnet-rpc.publicnode.com"
D = "deployments/bsc-testnet"
OUT = f"{D}/epk-v2.1-evidence.json"
NATIVE = "0x" + "00" * 20


def rpc(method, *params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)}).encode()
    req = urllib.request.Request(RPC, body, {"Content-Type": "application/json", "User-Agent": "epk-evidence/1.0"})
    out = json.load(urllib.request.urlopen(req, timeout=30))
    if "error" in out:
        raise RuntimeError(out["error"])
    return out["result"]


def amount(word_hex):
    """exact decimal string of an 18-decimals amount"""
    v = Decimal(int(word_hex, 16)) / Decimal(10 ** 18)
    s = format(v, "f")
    return s.rstrip("0").rstrip(".") if "." in s else s


def pad(addr):
    return "0x" + addr.lower()[2:].rjust(64, "0")


def main():
    dep = json.load(open(f"{D}/epk-v2.1.json"))
    run = json.load(open(f"{D}/epk-v2.1-run.json"))
    deploy_txs = json.load(open("broadcast/DeployV21Demo.s.sol/97/run-latest.json"))["transactions"]
    allowed_txs = json.load(open("broadcast/RunV21Demo.s.sol/97/allowed-latest.json"))["transactions"]
    control_tx = json.load(open("broadcast/RunV21Demo.s.sol/97/control-latest.json"))["transactions"][0]
    block_tx = json.load(open("broadcast/RunV21Demo.s.sol/97/blockSupplier-latest.json"))["transactions"][0]
    attacks = json.load(open(f"{D}/epk-v2.1-attacks-results.json"))["results"] + \
        json.load(open(f"{D}/epk-v2.1-blocked-results.json"))["results"]

    pancake_factory = "0x6725F303b657a9451d8BA641348b6761A6CC7a17"
    get_pair = selector("getPair(address,address)")

    def pair(a, b):
        r = rpc("eth_call", {"to": pancake_factory, "data": get_pair + pad(a)[2:] + pad(b)[2:]}, "latest")
        return "0x" + r[-40:]

    tusd_pool = pair(dep["wbnb"], dep["tusd"])
    busd_pool = pair(dep["wbnb"], dep["busd"])

    contracts_spec = [
        ("implementation_2_1_0", dep["implementation_2_1_0"], "EPKVault 2.1.0 implementation", "out/EPKVault.sol/EPKVault.json"),
        ("registry", dep["registry"], "EPKRegistry (2.1 demo, separate from the 2.0 demo)", "out/EPKRegistry.sol/EPKRegistry.json"),
        ("factory", dep["factory"], "EPKVaultFactory (2.1 demo)", "out/EPKVaultFactory.sol/EPKVaultFactory.json"),
        ("vault", dep["vault"], "EPKVault 2.1.0 demo vault (proxy)", "out/EPKVaultFactory.sol/EPKVaultProxy.json"),
        ("dexGuard", dep["dexGuard"], "DexGuard", "out/DexGuard.sol/DexGuard.json"),
        ("threatFeed", dep["threatFeed"], "ThreatFeed V2 (ThreatFeedGuard)", "out/ThreatFeedGuard.sol/ThreatFeedGuard.json"),
        ("compositeGuard", dep["compositeGuard"], "CompositeGuard (ThreatFeed V2 + DexGuard)", "out/CompositeGuard.sol/CompositeGuard.json"),
        ("token", dep["tusd"], "tUSD — the demo's test stablecoin", "out/EPKTestUSD.sol/EPKTestUSD.json"),
        ("tusdFeed", dep["tusdFeed"], "fixed $1 test feed for tUSD", "out/EPKFixedPriceFeed.sol/EPKFixedPriceFeed.json"),
        ("router", dep["router"], "PancakeSwap V2 router (BSC Testnet, not ours)", None),
        ("tusdPool", tusd_pool, "PancakeSwap tUSD/WBNB pool seeded at the Chainlink price", None),
        ("busd", dep["busd"], "BUSD (BSC Testnet, not ours)", None),
        ("busdPool", busd_pool, "PancakeSwap WBNB/BUSD pool (BSC Testnet, not ours)", None),
        ("bnbUsdFeed", dep["bnbUsdFeed"], "Chainlink BNB / USD (BSC Testnet)", None),
        ("busdUsdFeed", dep["busdUsdFeed"], "Chainlink BUSD / USD (BSC Testnet)", None),
    ]
    contracts = {}
    for key, addr, label, artifact in contracts_spec:
        code = rpc("eth_getCode", addr, "latest")
        c = {"address": addr, "label": label, "codeHash": "0x" + keccak(bytes.fromhex(code[2:])).hex()}
        if artifact:
            c["artifact"] = artifact
        contracts[key] = c
    contracts["implementation_2_1_0"].update({"pinnedInRegistry": True, "vaultVersion": 20100})
    contracts["vault"].update({"proxyImplementation": "implementation_2_1_0", "createdAtBlock": dep["createdAtBlock"]})

    roles = {k: dep[k] for k in ("admin", "guardian1", "guardian2", "recovery", "sessionManager", "operator", "agent",
                                 "responder", "supplier", "attacker")}
    sessions = {"guarded": run["sessionGuarded"], "unguarded": run["sessionUnguarded"]}
    TRANSFER = "Transfer(address,address,uint256)"

    def receipt(h):
        return rpc("eth_getTransactionReceipt", h)

    def log_data(rc, emitter, event, topics):
        for lg in rc["logs"]:
            if lg["address"].lower() == emitter.lower() and lg["topics"][0] == topic0(event) and \
                    all(lg["topics"][i + 1] == pad(t) for i, t in enumerate(topics)):
                return lg["data"][2:]
        raise RuntimeError(f"{event} not found in {rc['transactionHash']}")

    def words(data, n):
        return [amount(data[64 * i:64 * i + 64]) for i in range(n)]

    def by_selector(txs, sig):
        sel = selector(sig)
        return [t for t in txs if t["transaction"]["input"].startswith(sel)]

    txs = []

    def add(step, what, h, frm, to, events=None, expect="success", error=None):
        t = {"step": step, "what": what, "tx": h, "from": frm, "to": to, "expect": expect}
        if events:
            t["events"] = events
        if error:
            t["error"] = error
        txs.append(t)

    # ---- setup (selected transactions) ------------------------------------------------------------
    h = by_selector(deploy_txs, "createVault(address[],uint256,address,bytes32)")[0]["hash"]
    add("D1", "admin creates a separate EPKVault 2.1.0 through the 2.1 demo factory", h, "admin", "factory",
        [{"emitter": "factory", "event": "VaultCreated(address,address,uint256,address)", "indexed": ["vault", "admin"]}])
    h = by_selector(deploy_txs, "addLiquidityETH(address,uint256,uint256,uint256,address,uint256)")[0]["hash"]
    rc = receipt(h)
    seeded = words(log_data(rc, dep["tusd"], TRANSFER, [dep["admin"], tusd_pool]), 1)
    add("D2", "admin seeds a tUSD/WBNB pool at the Chainlink BNB price (0.03 BNB)", h, "admin", "router",
        [{"emitter": "token", "event": TRANSFER, "indexed": ["admin", "tusdPool"], "data": seeded}])
    h = by_selector(deploy_txs, "createPolicy(address,uint48,uint128,address)")[0]["hash"]
    add("D3", "trading policy for the operator key, guarded by ThreatFeed V2 + DexGuard", h, "admin", "vault",
        [{"emitter": "vault", "event": "PolicyUpdated(uint256,address,uint48,uint128,address)", "indexed": ["uint:0", "operator"]}])
    h = by_selector(deploy_txs, "setEnvelopeGuard(uint256,address)")[0]["hash"]
    add("D4", "agent-session envelope 1 gets the same guard (envelope 2 stays unguarded on purpose)", h, "admin", "vault",
        [{"emitter": "vault", "event": "EnvelopeGuardSet(uint256,address)", "indexed": ["uint:1", "compositeGuard"]}])
    h = by_selector(deploy_txs, "finalizeSetup()")[0]["hash"]
    add("D5", "setup finished: from now on every loosening needs the 1-hour timelock", h, "admin", "vault",
        [{"emitter": "vault", "event": "SetupFinalized()"}])

    # ---- allowed trades -----------------------------------------------------------------------------
    ex = by_selector(allowed_txs, "execute(uint256,(address,uint256,bytes)[],uint256,bytes,bytes)")
    op = by_selector(allowed_txs, "openSession(uint256,address,address,uint48)")
    rc = receipt(ex[0]["hash"])
    got = words(log_data(rc, dep["tusd"], TRANSFER, [tusd_pool, dep["vault"]]), 1)
    out = words(log_data(rc, dep["vault"], "Outflow(address,uint256,uint256)", [NATIVE]), 2)
    add("S1", "operator: vault swaps 0.0001 BNB for tUSD on PancakeSwap — at a fair price, output to the vault",
        ex[0]["hash"], "operator", "vault",
        [{"emitter": "vault", "event": "Executed(uint256,address,address,uint256,uint256)", "indexed": ["uint:0", "operator", "operator"]},
         {"emitter": "vault", "event": "Outflow(address,uint256,uint256)", "indexed": [NATIVE], "data": out, "unit": "BNB"},
         {"emitter": "token", "event": TRANSFER, "indexed": ["tusdPool", "vault"], "data": got}])
    rc = receipt(ex[1]["hash"])
    sold = words(log_data(rc, dep["tusd"], TRANSFER, [dep["vault"], tusd_pool]), 1)
    add("S2", "operator: vault sells 0.05 tUSD for BNB (approve, swap, allowance reset)", ex[1]["hash"], "operator", "vault",
        [{"emitter": "vault", "event": "Executed(uint256,address,address,uint256,uint256)", "indexed": ["uint:0", "operator", "operator"]},
         {"emitter": "token", "event": TRANSFER, "indexed": ["vault", "tusdPool"], "data": sold}])
    add("S3", "operator: vault pays the supplier 1 tUSD (plain payments pass the guards)", ex[2]["hash"], "operator", "vault",
        [{"emitter": "token", "event": TRANSFER, "indexed": ["vault", "supplier"], "data": ["1"]}])
    add("S4", "session manager opens an AI-agent session in the GUARDED envelope 1", op[0]["hash"], "sessionManager", "vault",
        [{"emitter": "vault", "event": "SessionOpened(uint256,uint256,address,address,uint48)",
          "indexed": ["session:guarded", "uint:1", "agent"]}])
    add("S5", "session manager opens an AI-agent session in the UNGUARDED envelope 2", op[1]["hash"], "sessionManager", "vault",
        [{"emitter": "vault", "event": "SessionOpened(uint256,uint256,address,address,uint48)",
          "indexed": ["session:unguarded", "uint:2", "agent"]}])
    rc = receipt(ex[3]["hash"])
    got = words(log_data(rc, dep["tusd"], TRANSFER, [tusd_pool, dep["vault"]]), 1)
    add("S6", "AI agent, on its own, swaps 0.0001 BNB for tUSD inside the guarded session", ex[3]["hash"], "agent", "vault",
        [{"emitter": "vault", "event": "Executed(uint256,address,address,uint256,uint256)",
          "indexed": ["session:guarded", "agent", "agent"]},
         {"emitter": "token", "event": TRANSFER, "indexed": ["tusdPool", "vault"], "data": got}])

    # ---- attacks (all rejected on-chain) ---------------------------------------------------------------
    words_for = {
        "a_recipientAttacker": ("A1", "operator key signs a swap whose output goes to the attacker"),
        "b_minOutOne": ("A2", "operator key signs a swap that accepts any price (minimum out = 1)"),
        "c_mispricedRealPool": ("A3", "operator key signs a swap on the REAL WBNB/BUSD pool at that pool's own quote (~38 % below Chainlink)"),
        "d_feeOnTransferFunction": ("A4", "operator key uses an unsupported router function (fee-on-transfer variant)"),
        "e_farDeadline": ("A5", "operator key signs a swap valid for 2 days (to run later at a worse price)"),
        "f_approveNonRouter": ("A6", "operator key approves a non-router (the supplier) to pull tUSD"),
        "g_unlistedToken": ("A7", "operator key swaps into a token that is not on the guard's list (CAKE)"),
        "h_sessionToAttacker": ("A8", "AI agent (guarded session) sends a swap's output to the attacker"),
        "i_unguardedSessionSwap": ("A9", "AI agent uses the UNGUARDED session to call the router — the other path"),
        "j_removeGuardWithoutTimelock": ("A10", "admin key tries to remove the session guard without the timelock"),
        "k_payBlockedSupplier": ("A12", "after the block: operator key tries to pay the supplier again"),
    }
    sender = {"operator": "operator", "agent21": "agent", "admin21": "admin"}
    for r in attacks:
        step, what = words_for[r["attack"]]
        add(step, what, r["tx"], sender[r["from"]], "vault", expect="reverted", error=r["error"])

    # ---- the plain-wallet control trade and the threat-feed block --------------------------------------
    rc = receipt(control_tx["hash"])
    got_busd = words(log_data(rc, dep["busd"], TRANSFER, [busd_pool, dep["operator"]]), 1)
    add("C1", "control: a PLAIN wallet (no EPK) makes the same 0.0001 BNB -> BUSD trade on the real pool", control_tx["hash"],
        "operator", "router", [{"emitter": "busd", "event": TRANSFER, "indexed": ["busdPool", "operator"], "data": got_busd, "unit": "BUSD"}])
    add("A11", "ThreatFeed V2: a responder blocks the supplier (reported as a drainer) — instantly", block_tx["hash"],
        "responder", "threatFeed",
        [{"emitter": "threatFeed", "event": "Blocked(address,address,bytes32)", "indexed": ["supplier", "responder"]}])

    def block_of(t):
        return int(receipt(t["tx"])["blockNumber"], 16)

    for t in txs:
        t["_block"] = block_of(t)
    txs.sort(key=lambda t: (t["_block"], t["step"]))
    att = [t for t in txs if t["expect"] == "reverted"]
    window = {"label": "attacks A1-A12 (no tUSD may leave the vault)", "fromBlock": att[0]["_block"] - 1,
              "toBlock": att[-1]["_block"]}
    for t in txs:
        del t["_block"]

    ev = {
        "about": "Machine-readable claims of the EPK 2.1 guard demo on BSC Testnet: a separate EPKVault 2.1.0 with DexGuard, "
                 "ThreatFeed V2 and CompositeGuard on the real PancakeSwap V2 testnet router and real Chainlink feeds. "
                 "scripts/v2/verify_evidence.py --evidence <this file> --doc docs/TESTNET_V21.md checks every claim. "
                 "Amounts have 18 decimals. Testnet only; not audited.",
        "chainId": 97,
        "tokenSymbol": "tUSD",
        "contracts": contracts,
        "roles": roles,
        "sessions": sessions,
        "transactions": txs,
        "checkpoints": [],
        "attackWindows": [window],
    }
    json.dump(ev, open(OUT, "w", encoding="utf-8", newline="\n"), indent=1)
    print(f"wrote {OUT}: {len(contracts)} contracts, {len(txs)} transactions "
          f"({len(att)} rejected), attack window {window['fromBlock']}..{window['toBlock']}")


if __name__ == "__main__":
    main()
