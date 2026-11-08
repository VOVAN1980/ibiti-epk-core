// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {EPKVault} from "../../contracts/v2/EPKVault.sol";
import {EPKVaultDemoRelease} from "./demo/EPKVaultDemoRelease.sol";

/// @title Step 5 — opt-in upgrade without moving funds (BSC testnet)
/// Phase 1 (>= 7 days after DeployV2, when the 2.0.1 release is approved):
///   forge script scripts/v2/DemoUpgrade.s.sol:DemoUpgrade --sig "schedule()" --rpc-url $BSC_RPC_URL --broadcast
/// Phase 2 (>= 2 days later):
///   forge script scripts/v2/DemoUpgrade.s.sol:DemoUpgrade --sig "execute()" --rpc-url $BSC_RPC_URL --broadcast
contract DemoUpgrade is Script {
    string internal constant IN_CORE = "deployments/bsc-testnet/epk-v2.json";
    string internal constant IN_VAULT = "deployments/bsc-testnet/epk-v2-vault.json";
    bytes32 internal constant SALT = keccak256("EPK demo: upgrade to 2.0.1");

    function _vault() internal view returns (EPKVault) {
        return EPKVault(payable(vm.parseJsonAddress(vm.readFile(IN_VAULT), ".vault")));
    }

    function _release() internal view returns (address) {
        return vm.parseJsonAddress(vm.readFile(IN_CORE), ".release_2_0_1");
    }

    function schedule() external {
        require(block.chainid == 97 || block.chainid == 11155111 || block.chainid == 31337, "EPK: test networks only");
        EPKVault vault = _vault();
        vm.broadcast(vm.envUint("PRIVATE_KEY"));
        vault.scheduleUpgrade(_release(), SALT);
        console2.log("Upgrade to 2.0.1 scheduled. Executable after (unix time):", block.timestamp + 2 days);
    }

    function execute() external {
        require(block.chainid == 97 || block.chainid == 11155111 || block.chainid == 31337, "EPK: test networks only");
        EPKVault vault = _vault();
        address token = vm.parseJsonAddress(vm.readFile(IN_CORE), ".token");
        uint256 before = vault.availableToSpend(token);
        console2.log("Version before:", vault.vaultVersion());

        bytes memory op = vault.upgradeOperationData(_release()); // read BEFORE broadcasting
        vm.broadcast(vm.envUint("PRIVATE_KEY"));
        vault.executeScheduled(op, SALT);

        console2.log("Version after :", vault.vaultVersion());
        console2.log(EPKVaultDemoRelease(payable(address(vault))).releaseNote());
        console2.log("Same vault address:", address(vault));
        console2.log("Limit state unchanged:", vault.availableToSpend(token) >= before);
    }
}
