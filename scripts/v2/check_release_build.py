"""Compare the contracts of a test-network release with this repository's build, byte for byte.

Reads deployments/<network>/epk-release.json (scripts/v2/ReleaseTestnet.s.sol) and checks the release, its
emergency module, the registry with a security council and the public factory against `out/` (run
`forge build` first), with immutables masked — the same rule as `verify_evidence.py --build`. No keys needed.

    python scripts/v2/check_release_build.py bsc
    python scripts/v2/check_release_build.py opbnb
"""

import json
import sys
import urllib.request

NETWORKS = {
    "bsc": ("deployments/bsc-testnet/epk-release.json", "https://data-seed-prebsc-1-s1.bnbchain.org:8545"),
    "opbnb": ("deployments/opbnb-testnet/epk-release.json", "https://opbnb-testnet-rpc.bnbchain.org"),
}
CONTRACTS = [
    ("implementation", "EPKVault release", "out/EPKVault.sol/EPKVault.json"),
    ("emergencyModule", "its emergency module", "out/EPKVault.sol/EPKVaultEmergency.json"),
    ("councilRegistry", "registry with a security council", "out/EPKRegistry.sol/EPKRegistry.json"),
    ("factory", "public factory", "out/EPKVaultFactory.sol/EPKVaultFactory.json"),
]


def code_at(rpc, address):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getCode", "params": [address, "latest"]}).encode()
    req = urllib.request.Request(rpc, body, {"Content-Type": "application/json", "User-Agent": "epk-check"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["result"]


def main():
    net = sys.argv[1] if len(sys.argv) > 1 else "bsc"
    record, rpc = NETWORKS[net]
    rel = json.load(open(record, encoding="utf-8"))
    ok = True
    for key, label, artifact in CONTRACTS:
        address = rel[key]
        art = json.load(open(artifact, encoding="utf-8"))["deployedBytecode"]
        local = bytearray.fromhex(art["object"][2:])
        onchain = bytearray.fromhex(code_at(rpc, address)[2:])
        for refs in art.get("immutableReferences", {}).values():
            for ref in refs:
                for buf in (local, onchain):
                    buf[ref["start"]:ref["start"] + ref["length"]] = bytes(ref["length"])
        same = len(onchain) > 0 and local == onchain
        ok &= same
        print(f"{'OK ' if same else 'BAD'} {label} {address}: {len(onchain)} bytes, "
              f"{'equals' if same else 'DIFFERS from'} {artifact} (immutables masked)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
