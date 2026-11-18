#!/usr/bin/env bash
# Read-only checks of the current vault release on a public test network and of the registry with a security
# council (docs/TESTNET_RELEASE.md). No keys needed; reads deployments/<network>/epk-release.json.
#   bash scripts/v2/check_release.sh bsc      (BSC Testnet)
#   bash scripts/v2/check_release.sh opbnb    (opBNB Testnet)
# Each fastTrack line simulates the call (eth_call) and names the custom error it reverts with.
net=$1
if [ "$net" = opbnb ]; then R=https://opbnb-testnet-rpc.bnbchain.org; F=deployments/opbnb-testnet/epk-release.json; else R=https://data-seed-prebsc-1-s1.bnbchain.org:8545; F=deployments/bsc-testnet/epk-release.json; fi
j() { python -c "import json; print(json.load(open('$F'))['$1'])"; }
IMPL=$(j implementation); OLD=$(j registry); NEW=$(j councilRegistry); C=$(j council); FAC=$(j factory); V=$(j upgradeVault); TOK=$(j token)
OWNER=$(cast call $NEW 'owner()(address)' --rpc-url $R)
STRANGER=0x000000000000000000000000000000000000dEaD
rev() { # prints the custom error a simulated call reverts with
  out=$(cast call --from $1 $NEW "fastTrack(address)" $IMPL --rpc-url $R 2>&1)
  data=$(printf '%s' "$out" | grep -o '0x[0-9a-fA-F]\{8,\}' | tail -1)
  for e in "NotCouncil()" "NotPending(address)" "NotAPatch(uint64,uint64)" "UnknownRelease(address)"; do
    [ "${data:0:10}" = "$(cast sig "$e")" ] && { echo "reverts $e"; return; }
  done; echo "reverts? $out" | head -c 200; echo
}
echo "== $net, $(date -u +%Y-%m-%dT%H:%M:%SZ), RPC $R"
echo "release $IMPL: vaultVersion() = $(cast call $IMPL 'vaultVersion()(uint64)' --rpc-url $R), code hash $(cast code $IMPL --rpc-url $R | cast keccak) (recorded: $(j codehash))"
echo "-- registry with a security council $NEW"
echo "council() = $(cast call $NEW 'council()(address)' --rpc-url $R)   (recorded: $C)"
echo "owner() = $OWNER"
echo "approvalDelay() = $(cast call $NEW 'approvalDelay()(uint256)' --rpc-url $R) s"
echo "isApproved(release) = $(cast call $NEW 'isApproved(address)(bool)' $IMPL --rpc-url $R), versionOf(release) = $(cast call $NEW 'versionOf(address)(uint64)' $IMPL --rpc-url $R), isUrgent(release) = $(cast call $NEW 'isUrgent(address)(bool)' $IMPL --rpc-url $R)"
echo "fastTrack(release) simulated from the owner: $(rev $OWNER)"
echo "fastTrack(release) simulated from a stranger: $(rev $STRANGER)"
echo "fastTrack(release) simulated from the council: $(rev $C)   (the genesis release is already active: nothing to rush)"
echo "-- public factory $FAC"
echo "implementation() = $(cast call $FAC 'implementation()(address)' --rpc-url $R), registry() = $(cast call $FAC 'registry()(address)' --rpc-url $R)"
echo "-- the registry existing vaults use $OLD"
echo "isApproved(release) = $(cast call $OLD 'isApproved(address)(bool)' $IMPL --rpc-url $R), versionOf(release) = $(cast call $OLD 'versionOf(address)(uint64)' $IMPL --rpc-url $R)"
if cast call $OLD 'council()(address)' --rpc-url $R >/dev/null 2>&1; then echo "council(): answers (unexpected)"; else echo "council(): reverts — a registry from before the fast track has no council, so its vaults keep the normal path"; fi
echo "-- upgrade-demo vault $V"
echo "vaultVersion() = $(cast call $V 'vaultVersion()(uint64)' --rpc-url $R), implementation slot = 0x$(cast storage $V 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url $R | tail -c 41), registry() = $(cast call $V 'registry()(address)' --rpc-url $R)"
echo "test tokens in the vault = $(cast call $TOK 'balanceOf(address)(uint256)' $V --rpc-url $R)   (recorded before the upgrade: $(j upgradeVaultTokensBefore))"
