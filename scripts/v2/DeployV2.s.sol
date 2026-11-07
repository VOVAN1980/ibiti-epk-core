// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {EPKVault} from "../../contracts/v2/EPKVault.sol";
import {EPKRegistry} from "../../contracts/v2/EPKRegistry.sol";
import {EPKVaultFactory} from "../../contracts/v2/EPKVaultFactory.sol";
import {EPKVaultDemoRelease} from "./demo/EPKVaultDemoRelease.sol";
import {EPKDemoToken} from "./demo/EPKDemoToken.sol";

/// @title Step 1 — deploy EPK v2 core (BSC testnet)
/// @notice Implementation 2.0.0, registry (owner = deployer), factory, the 2.0.1 demo release (its
///         7-day public approval window starts now) and a demo token. Writes the addresses to
///         deployments/bsc-testnet/epk-v2.json.
/// forge script scripts/v2/DeployV2.s.sol:DeployV2 --rpc-url $BSC_RPC_URL --broadcast
contract DeployV2 is Script {
    string internal constant OUT = "deployments/bsc-testnet/epk-v2.json";

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        EPKVault implementation = new EPKVault();
        EPKRegistry registry = new EPKRegistry(deployer, address(implementation));
        EPKVaultFactory factory = new EPKVaultFactory(address(implementation), address(registry));
        EPKVaultDemoRelease release = new EPKVaultDemoRelease();
        registry.proposeRelease(address(release)); // usable after APPROVAL_DELAY (7 days)
        EPKDemoToken token = new EPKDemoToken();
        vm.stopBroadcast();

        string memory o = "v2";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "deployer", deployer);
        vm.serializeAddress(o, "implementation", address(implementation));
        vm.serializeAddress(o, "registry", address(registry));
        vm.serializeAddress(o, "factory", address(factory));
        vm.serializeAddress(o, "release_2_0_1", address(release));
        vm.serializeUint(o, "release_2_0_1_usableFrom", block.timestamp + registry.APPROVAL_DELAY());
        string memory json = vm.serializeAddress(o, "token", address(token));
        vm.writeJson(json, OUT);

        console2.log("EPKVault 2.0.0 implementation:", address(implementation));
        console2.log("EPKRegistry                  :", address(registry));
        console2.log("EPKVaultFactory              :", address(factory));
        console2.log("EPKVault 2.0.1 demo release  :", address(release));
        console2.log("EPK demo token (eUSD)        :", address(token));
    }
}
