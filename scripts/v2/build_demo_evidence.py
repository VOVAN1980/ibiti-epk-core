# SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
"""Write deployments/bsc-testnet/epk-v2-evidence.json — the machine-readable claims of the EPK demo on BSC Testnet
(vault on the current EPKVault release, agent session, attacks, panic and recovery, stolen admin key vs the
Watchtower, emergency evacuation to the owner's cold wallet) — from
the deployment / run files, the mined receipts and the vault's state at fixed blocks.

Every claim is then re-checked against the chain by:
    python scripts/v2/verify_evidence.py

Checkpoint values are read from the chain at their blocks and must equal what the demo did (10,000 eUSD funded,
50 paid, 10 paid, ...): the builder stops if any differs.
"""
import json
import sys
from decimal import Decimal

sys.path.insert(0, "scripts/v2")
from verify_evidence import NODES, Chain, keccak, selector, topic0  # noqa: E402  (pure Python, no packages)

D = "deployments/bsc-testnet"
OUT = f"{D}/epk-v2-evidence.json"
IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
chain = Chain(NODES)
E18 = 10 ** 18


def broadcast(script, sig="run"):
    return json.load(open(f"broadcast/{script}/97/{sig}-latest.json"))["transactions"]


def pad(v):
    return "0x" + (v.lower()[2:] if isinstance(v, str) else format(v, "x")).rjust(64, "0")


def by_selector(txs, sig):
    sel = selector(sig)
    return [t["hash"] for t in txs if t["transaction"]["input"].startswith(sel)]


def main():
    core = json.load(open(f"{D}/epk-v2.json"))
    rel = json.load(open(f"{D}/epk-release.json"))
    vtext = f"{rel['version'] // 10000}.{rel['version'] // 100 % 100}.{rel['version'] % 100}"
    v = json.load(open(f"{D}/epk-v2-vault.json"))
    attacks = json.load(open(f"{D}/epk-v2-attacks.json"))
    after = json.load(open(f"{D}/epk-v2-after-panic.json"))
    stolen = json.load(open(f"{D}/epk-v2-stolen-key.json"))
    evac = json.load(open(f"{D}/epk-v2-evacuation.json"))
    results = {r["attack"]: r for f in ("attacks", "after-panic", "stolen-key", "evacuation")
               for r in json.load(open(f"{D}/epk-v2-{f}-results.json"))["results"]}
    vault, token = v["vault"], core["token"]

    setup, session = broadcast("SetupDemoVault.s.sol"), broadcast("DemoSession.s.sol")
    panic, recover = broadcast("DemoPanic.s.sol", "panicAndScheduleUnpause"), broadcast("DemoPanic.s.sol", "recover")
    stolen_tx = broadcast("DemoStolenKey.s.sol")
    redirect_tx = broadcast("DemoEvacuation.s.sol", "redirect")
    evacuate_tx = broadcast("DemoEvacuation.s.sol", "evacuate")

    contracts_spec = [
        ("implementation", rel["implementation"], f"EPKVault {vtext} implementation", "out/EPKVault.sol/EPKVault.json"),
        ("emergencyModule", rel["emergencyModule"], f"EPKVaultEmergency — the {vtext} release's emergency module, deployed by the implementation",
         "out/EPKVault.sol/EPKVaultEmergency.json"),
        ("registry", core["registry"], "EPKRegistry (5-minute test-network release window)", None),
        ("factory", rel["factory"], f"EPKVaultFactory for {vtext} — the SDK's public factory", "out/EPKVaultFactory.sol/EPKVaultFactory.json"),
        ("token", token, "EPK Demo USD (eUSD) test token", None),
        ("vault", vault, "Demo vault (customer proxy)", "out/EPKVaultFactory.sol/EPKVaultProxy.json"),
    ]
    contracts = {}
    for key, addr, label, artifact in contracts_spec:
        code = chain("eth_getCode", addr, "latest")
        c = {"address": addr, "label": label, "codeHash": "0x" + keccak(bytes.fromhex(code[2:])).hex()}
        if artifact:
            c["artifact"] = artifact
        contracts[key] = c
    contracts["implementation"].update({"pinnedInRegistry": True, "vaultVersion": rel["version"]})

    def receipt(h):
        return chain("eth_getTransactionReceipt", h)

    def block_of(h):
        return int(receipt(h)["blockNumber"], 16)

    create = by_selector(setup, "createVault(address[],uint256,address,bytes32)")[0]
    contracts["vault"].update({"proxyImplementation": "implementation", "createdAtBlock": block_of(create)})
    roles = {k: v[k] for k in ("admin", "guardian1", "guardian2", "recovery", "sessionManager", "agent", "coldWallet")}
    sessions = {"demo": str(attacks["sessionId"]), "recovery": str(after["newSessionId"])}

    T = "Transfer(address,address,uint256)"
    EX = "Executed(uint256,address,address,uint256,uint256)"
    OPEN = "SessionOpened(uint256,uint256,address,address,uint48)"
    execute_sig = "execute(uint256,(address,uint256,bytes)[],uint256,bytes,bytes)"
    txs = []

    def add(step, what, h, frm, to, events=None, expect="success", error=None):
        t = {"step": step, "what": what, "tx": h, "from": frm, "to": to, "expect": expect}
        if events:
            t["events"] = events
        if error:
            t["error"] = error
        txs.append(t)

    def attack(step, name, what, frm):
        r = results[name]
        assert r["status"] == "rejected", (name, r)
        add(step, what, r["tx"], frm, "vault", expect="reverted", error=r["error"])

    add("1", f"admin creates the demo vault through the public {vtext} factory (5-minute timelock, the owner's cold wallet registered)",
        create, "admin", "factory",
        [{"emitter": "factory", "event": "VaultCreated(address,address,uint256,address)", "indexed": ["vault", "admin"]}])
    fin = by_selector(setup, "finalizeSetup()")[0]
    add("2", "setup finalized: 1,000 eUSD/day vault limit, 100 eUSD/day per agent session, only the treasury allowed",
        fin, "admin", "vault", [{"emitter": "vault", "event": "SetupFinalized()"}])
    add("3a", "session manager opens an AI-agent session (3 days)", by_selector(session, "openSession(uint256,address,address,uint48)")[0],
        "sessionManager", "vault", [{"emitter": "vault", "event": OPEN, "indexed": ["session:demo", "uint:1", "agent"]}])
    pay1 = by_selector(session, execute_sig)[0]
    add("3b", "the agent pays 50 eUSD to the treasury on its own", pay1, "agent", "vault",
        [{"emitter": "vault", "event": EX, "indexed": ["session:demo", "agent", "agent"]},
         {"emitter": "vault", "event": "Outflow(address,uint256,uint256)", "indexed": ["token"], "data": ["50", "950"]},
         {"emitter": "token", "event": T, "indexed": ["vault", "admin"], "data": ["50"]}])
    attack("4a", "a_overBudget", "agent pays 60 eUSD with 50 left in its budget", "agent")
    attack("4b", "b_unknownDestination", "agent pays to a non-allowlisted address", "agent")
    attack("4c", "c_callNotAllowed", "agent calls approve (not in its envelope)", "agent")
    attack("4d", "d_forgedSignature", "batch signed by a key that is not the session key", "agent")
    attack("4e", "e_notTheAgent", "a stranger submits the agent's valid signature", "guardian2")
    pnc = by_selector(panic, "panic()")[0]
    add("5a", "a guardian presses panic: everything stops at once", pnc, "guardian1", "vault",
        [{"emitter": "vault", "event": "Paused(address)", "indexed": ["guardian1"]},
         {"emitter": "vault", "event": "EpochBumped(uint64,address)", "indexed": ["guardian1"]}])
    sch = by_selector(panic, "schedule(bytes,bytes32)")[0]
    add("5b", "admin schedules unpause through the timelock (5 minutes on test networks)", sch, "admin", "vault",
        [{"emitter": "vault", "event": "OperationScheduled(bytes32,bytes,bytes32,uint64,address)"}])
    unp = by_selector(recover, "executeScheduled(bytes,bytes32)")[0]
    add("6a", "admin executes the timelocked unpause (5 minutes after the panic)", unp, "admin", "vault",
        [{"emitter": "vault", "event": "Unpaused()"}, {"emitter": "vault", "event": "OperationExecuted(bytes32)"}])
    add("6b", "session manager opens a new agent session", by_selector(recover, "openSession(uint256,address,address,uint48)")[0],
        "sessionManager", "vault", [{"emitter": "vault", "event": OPEN, "indexed": ["session:recovery", "uint:1", "agent"]}])
    pay2 = by_selector(recover, execute_sig)[0]
    add("6c", "the agent pays 10 eUSD through the new session", pay2, "agent", "vault",
        [{"emitter": "vault", "event": EX, "indexed": ["session:recovery", "agent", "agent"]},
         {"emitter": "vault", "event": "Outflow(address,uint256,uint256)", "indexed": ["token"], "data": ["10"]},
         {"emitter": "token", "event": T, "indexed": ["vault", "admin"], "data": ["10"]}])
    attack("6f", "f_oldSessionAfterPanic", "the agent tries to pay through the old (pre-panic) session", "agent")

    op = stolen["operationId"]
    w1 = by_selector(stolen_tx, "schedule(bytes,bytes32)")[0]
    add("W1", "attacker with the stolen admin key schedules addDestination(0xBAD1)", w1, "admin", "vault",
        [{"emitter": "vault", "event": "OperationScheduled(bytes32,bytes,bytes32,uint64,address)", "indexed": [op, "admin"]}])
    def cancel_of(op_id, from_block):
        for url in NODES:  # the Watchtower's cancel: the vault's OperationCancelled log for this operation
            try:
                last = min(from_block + 900, int(chain.only(url)("eth_blockNumber"), 16))
                logs = chain.only(url)("eth_getLogs", {"address": vault, "fromBlock": hex(from_block), "toBlock": hex(last),
                                                       "topics": [topic0("OperationCancelled(bytes32,address)"), op_id]})
            except Exception:  # noqa: BLE001 — try the next node
                continue
            if logs:
                return logs[0]
        raise AssertionError(f"the Watchtower's cancel of {op_id} was not found")

    b1 = block_of(w1)
    cancel = cancel_of(op, b1)
    add("W2", f"the Watchtower (guardian2 key) cancels it, {int(cancel['blockNumber'], 16) - b1} blocks later",
        cancel["transactionHash"], "guardian2", "vault",
        [{"emitter": "vault", "event": "OperationCancelled(bytes32,address)", "indexed": [op, "guardian2"]}])
    attack("W3", "g_executeCancelledChange", "attacker tries to execute the change anyway", "admin")

    op2 = evac["operationId"]
    e1 = by_selector(redirect_tx, "schedule(bytes,bytes32)")[0]
    add("E1", "attacker with the stolen admin key schedules setColdWallet(0xBAD2) — so that an evacuation would pay them",
        e1, "admin", "vault",
        [{"emitter": "vault", "event": "OperationScheduled(bytes32,bytes,bytes32,uint64,address)", "indexed": [op2, "admin"]}])
    eb = block_of(e1)
    c2 = cancel_of(op2, eb)
    add("E2", f"the Watchtower (guardian2 key) cancels it, {int(c2['blockNumber'], 16) - eb} blocks later",
        c2["transactionHash"], "guardian2", "vault",
        [{"emitter": "vault", "event": "OperationCancelled(bytes32,address)", "indexed": [op2, "guardian2"]}])
    attack("E3", "h_executeColdWalletChange", "attacker tries to execute the cold-wallet change anyway", "admin")
    attack("E4", "i_guardianEvacuates", "a guardian tries to evacuate — guardians stop, they never move funds", "guardian1")
    ev5 = by_selector(evacuate_tx, "evacuate(address[])")[0]
    add("E5", "the owner's recovery key evacuates everything to the cold wallet registered at setup (and pauses the vault)",
        ev5, "recovery", "vault",
        [{"emitter": "vault", "event": "Paused(address)", "indexed": ["recovery"]},
         {"emitter": "vault", "event": "EpochBumped(uint64,address)", "indexed": ["recovery"]},
         {"emitter": "vault", "event": "Evacuated(address,uint256,address,address)", "indexed": ["token", "coldWallet", "recovery"],
          "data": ["9940"]},
         {"emitter": "token", "event": T, "indexed": ["vault", "coldWallet"], "data": ["9940"]}])

    # ---- checkpoints: the vault's state at fixed blocks, read now and checked against what the demo did ----
    def state(b):
        tag = hex(b)
        bal = int(chain.call(token, selector("balanceOf(address)") + pad(vault)[2:], tag), 16)
        paused = bool(int(chain.call(vault, selector("paused()"), tag), 16))
        impl = "0x" + chain("eth_getStorageAt", vault, IMPL_SLOT, tag)[-40:]
        left = int(chain.call(vault, selector("availableToSpend(address)") + pad(token)[2:], tag), 16)
        return bal, paused, impl.lower(), left

    def budget(b, sid):
        return int(chain.call(vault, selector("budgetAvailable(uint256,address)") + pad(int(sid))[2:] + pad(token)[2:], hex(b)), 16)

    def eusd(x):
        s = format(Decimal(x) / E18, "f")
        return s.rstrip("0").rstrip(".") if "." in s else s

    impl = core["implementation"].lower()
    by_step = {t["step"]: block_of(t["tx"]) for t in txs}
    funded = block_of(by_selector(setup, "mint(address,uint256)")[0])
    cps = []

    def cp(label, b, want_bal, want_paused, with_impl=True, limit=None, sess=None):
        bal, paused, im, left = state(b)
        assert bal == want_bal * E18 and paused is want_paused and im == impl, (label, bal, paused, im)
        c = {"label": label, "block": b, "paused": paused}
        if with_impl:
            c["implementation"] = "implementation"
        c["eUSD"] = eusd(bal)
        if limit is not None:
            assert left == limit * E18, (label, left)
            c["vaultLimitLeft"] = eusd(left)
        if sess:
            got = budget(b, sessions[sess[0]])
            assert got == sess[1] * E18, (label, got)
            c["sessionBudgetLeft"] = {"session": sess[0], "value": eusd(got)}
        cps.append(c)

    cp("setup done, vault funded", funded, 10_000, False, limit=1_000)
    cp("right after the agent's 50 eUSD payment", by_step["3b"], 9_950, False, limit=950, sess=("demo", 50))
    cp("after all 5 attacks (nothing moved)", by_step["4e"], 9_950, False)
    cp("one block before the panic", by_step["5a"] - 1, 9_950, False, with_impl=False)
    cp("panic block", by_step["5a"], 9_950, True)
    cp("one block before the timelocked unpause", by_step["6a"] - 1, 9_950, True, with_impl=False)
    cp("unpause block", by_step["6a"], 9_950, False)
    cp("right after the new session's 10 eUSD payment", by_step["6c"], 9_940, False, sess=("recovery", 90))
    cp("after the old session's attempt (nothing moved)", by_step["6f"], 9_940, False, with_impl=False)
    cp("after the attacker's attempt (nothing moved, still unpaused)", by_step["W3"], 9_940, False)
    cp("after the guardian's evacuation attempt (nothing moved)", by_step["E4"], 9_940, False)
    cp("after the evacuation: everything in the owner's cold wallet, the vault paused", by_step["E5"], 0, True)

    windows = [
        {"label": "attacks 4a-4e", "fromBlock": by_step["3b"], "toBlock": by_step["4e"]},
        {"label": "old-session attempt 6f", "fromBlock": by_step["6c"], "toBlock": by_step["6f"]},
        {"label": "stolen admin key W1-W3", "fromBlock": by_step["W1"] - 1, "toBlock": by_step["W3"]},
        {"label": "cold-wallet redirect and guardian evacuation E1-E4", "fromBlock": by_step["E1"] - 1, "toBlock": by_step["E4"]},
    ]
    ev = {
        "about": f"Machine-readable claims of the EPK demo on BSC Testnet: a vault on EPKVault {vtext} created through the "
                 "public factory, an AI-agent session, rejected attacks, panic and timelocked recovery, a stolen admin key stopped "
                 "by the Watchtower, and an emergency evacuation to the owner's cold wallet. scripts/v2/verify_evidence.py checks every claim against the chain. Amounts are in eUSD "
                 "(18 decimals). Testnet only; not audited.",
        "chainId": 97,
        "contracts": contracts,
        "roles": roles,
        "sessions": sessions,
        "transactions": txs,
        "checkpoints": cps,
        "attackWindows": windows,
    }
    json.dump(ev, open(OUT, "w", encoding="utf-8", newline="\n"), indent=1)
    print(f"wrote {OUT}: {len(contracts)} contracts, {len(txs)} transactions "
          f"({sum(t['expect'] == 'reverted' for t in txs)} rejected), {len(cps)} checkpoints")


if __name__ == "__main__":
    main()
