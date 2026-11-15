// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {EPKVault} from "../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../contracts/v2/EPKVaultFactory.sol";
import {EPKRegistry} from "../../contracts/v2/EPKRegistry.sol";
import {EPKDemoToken} from "./demo/EPKDemoToken.sol";
import {EPKDemoNetwork} from "./demo/EPKDemoNetwork.sol";

/// @title Step 1 on a new test network — the EPK contracts and the demo token
/// @notice Deploys the current EPKVault release (its constructor deploys the release's emergency module), a
///         registry of releases that lists it as its genesis release, the public factory that creates vaults on
///         it, and the eUSD demo token. The deployer (PRIVATE_KEY) owns the registry. Writes
///         deployments/<network>/epk-v2.json, which the demo scripts read. Test networks only (EPK is not
///         audited); refuses to overwrite an existing record.
///   forge script scripts/v2/DeployStack.s.sol:DeployStack --rpc-url $RPC --broadcast --slow
contract DeployStack is Script {
    function run() external {
        string memory out = EPKDemoNetwork.file("epk-v2.json"); // reverts on a mainnet
        require(!vm.exists(out), "EPK: this network already has a record; move it away first");
        vm.createDir(EPKDemoNetwork.dir(), true);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        EPKVault implementation = new EPKVault();
        EPKRegistry registry = new EPKRegistry(deployer, address(implementation));
        EPKVaultFactory factory = new EPKVaultFactory(address(implementation), address(registry));
        EPKDemoToken token = new EPKDemoToken();
        vm.stopBroadcast();

        require(registry.isApproved(address(implementation)), "genesis release not listed");

        string memory o = "stack";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "deployer", deployer);
        vm.serializeAddress(o, "implementation", address(implementation));
        vm.serializeUint(o, "version", implementation.vaultVersion());
        vm.serializeBytes32(o, "codehash", address(implementation).codehash);
        // the release's emergency module: the first contract its constructor created
        vm.serializeAddress(o, "emergencyModule", vm.computeCreateAddress(address(implementation), 1));
        vm.serializeAddress(o, "registry", address(registry));
        vm.serializeAddress(o, "factory", address(factory));
        string memory json = vm.serializeAddress(o, "token", address(token));
        vm.writeJson(json, out);

        console2.log("EPKVault", implementation.vaultVersion(), address(implementation));
        console2.log("registry (release window, s):", address(registry), registry.approvalDelay());
        console2.log("factory:", address(factory));
        console2.log("eUSD demo token:", address(token));
    }
}
