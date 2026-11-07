"""Send prepared EPK v2 attack transactions so that each one is rejected ON-CHAIN (evidence).

Usage (from the repo root):
    python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2-attacks.json [--rpc-url URL]

For every entry `<name>` / `<name>_from` in the JSON it:
  1. simulates the call (eth_call) from that sender and decodes the EPKVault custom error;
  2. sends it anyway with a fixed gas limit (no gas estimation), so the rejection is mined;
  3. records tx hash, status and error in `<input>-results.json`.
Private keys are read from .env and passed to the local `cast` process (--private-key);
they are never printed or written anywhere.
"""
import json
import os
import re
import subprocess
import sys

KEY_FOR = {"agent": "V2_AGENT_PRIVATE_KEY", "guardian2": "V2_GUARDIAN2_PRIVATE_KEY"}


def load_env(path=".env"):
    env = {}
    with open(path, encoding="utf-8-sig") as f:
        for line in f:
            m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$", line.rstrip("\r\n"))
            if m:
                env[m.group(1)] = m.group(2).strip().strip('"')
    return env


def run(args, extra_env=None):
    e = dict(os.environ)
    if extra_env:
        e.update(extra_env)
    return subprocess.run(args, capture_output=True, text=True, env=e)


def error_table():
    out = run(["forge", "inspect", "contracts/v2/EPKVault.sol:EPKVault", "errors", "--json"])
    table = json.loads(out.stdout)
    return {("0x" + sel.removeprefix("0x")).lower(): name for name, sel in table.items()}


def main():
    path = sys.argv[1]
    rpc = sys.argv[sys.argv.index("--rpc-url") + 1] if "--rpc-url" in sys.argv else None
    env = load_env()
    rpc = rpc or env["BSC_RPC_URL"]
    vault = json.load(open("deployments/bsc-testnet/epk-v2-vault.json"))["vault"]
    attacks = json.load(open(path))
    errors = error_table()
    results = []

    for name in sorted(k for k in attacks if isinstance(attacks[k], str) and attacks[k].startswith("0x") and not k.endswith("_from")):
        sender_role = attacks.get(f"{name}_from", "agent")
        pk = env[KEY_FOR[sender_role]]
        sender = run(["cast", "wallet", "address", "--private-key", pk]).stdout.strip()
        data = attacks[name]

        sim = run(["cast", "call", vault, data, "--from", sender, "--rpc-url", rpc])
        m = re.search(r"0x[0-9a-fA-F]{8}", sim.stderr + sim.stdout)
        observed = errors.get(m.group(0).lower(), m.group(0)) if (sim.returncode != 0 and m) else "NOT REVERTED"

        sent = run(["cast", "send", vault, data, "--gas-limit", "900000", "--rpc-url", rpc, "--json",
                    "--private-key", pk])
        try:
            receipt = json.loads(sent.stdout)
            tx, status = receipt.get("transactionHash"), int(receipt.get("status", "0x0"), 16)
        except (json.JSONDecodeError, ValueError):
            tx, status = None, None
        results.append({"attack": name, "from": sender_role, "sender": sender, "error": observed,
                        "tx": tx, "status": "rejected" if status == 0 else ("SUCCEEDED" if status == 1 else "not sent")})
        print(f"{name:<28} {sender_role:<10} -> {observed:<28} tx {tx} [{results[-1]['status']}]")

    out = path.replace(".json", "-results.json")
    json.dump({"vault": vault, "results": results}, open(out, "w"), indent=2)
    print("results:", out)
    if any(r["status"] != "rejected" for r in results):
        sys.exit(1)


if __name__ == "__main__":
    main()
