// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {EPKVault} from "../../contracts/v2/EPKVault.sol";

/// @title Watchtower demo — "the admin key was stolen" (BSC testnet)
/// With the EPK Watchtower running (watchtower/epk_watchtower.py), an attacker who holds the real admin
/// key schedules the one change that would let money leave the vault for their own address. The
/// Watchtower cancels it with its guardian key before the timelock ends. This script then prepares the
/// attacker's attempt to execute the change anyway (deployments/bsc-testnet/epk-v2-stolen-key.json),
/// which scripts/v2/demo_attacks.py sends so that its rejection is recorded on-chain.
///   forge script scripts/v2/DemoStolenKey.s.sol:DemoStolenKey --rpc-url $BSC_RPC_URL --broadcast
contract DemoStolenKey is Script {
    string internal constant IN_VAULT = "deployments/bsc-testnet/epk-v2-vault.json";
    string internal constant OUT = "deployments/bsc-testnet/epk-v2-stolen-key.json";
    address internal constant ATTACKER = address(0xBAD1);
    bytes32 internal constant SALT = keccak256("EPK demo: stolen admin key");

    function run() external {
        // EPK is not audited: these scripts refuse to run on any mainnet
        require(block.chainid == 97 || block.chainid == 11155111 || block.chainid == 31337, "EPK: test networks only");
        EPKVault vault = EPKVault(payable(vm.parseJsonAddress(vm.readFile(IN_VAULT), ".vault")));
        bytes memory change = abi.encodeCall(EPKVault.addDestination, (ATTACKER));

        // the attacker uses the stolen admin key: "let the vault pay my address"
        vm.broadcast(vm.envUint("PRIVATE_KEY"));
        bytes32 id = vault.schedule(change, SALT);
        console2.log("Attacker scheduled addDestination(0xBAD1); operation id:");
        console2.logBytes32(id);
        console2.log("It could only take effect after (unix time):", block.timestamp + vault.delay());

        // the attacker's later attempt to push it through (sent by demo_attacks.py after the Watchtower acted)
        string memory o = "stolenKey";
        vm.serializeBytes32(o, "operationId", id);
        vm.serializeBytes(o, "g_executeCancelledChange", abi.encodeCall(EPKVault.executeScheduled, (change, SALT)));
        string memory json = vm.serializeString(o, "g_executeCancelledChange_from", "admin");
        vm.writeJson(json, OUT);
    }
}
