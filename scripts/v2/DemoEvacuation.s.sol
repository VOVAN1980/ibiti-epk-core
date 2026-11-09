// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {EPKVault, IEPKVaultEmergency} from "../../contracts/v2/EPKVault.sol";

/// @title Emergency evacuation on the demo vault (BSC Testnet, vault 2.3.0+) — docs/EVACUATION_v2.md
/// @notice With the Watchtower running (watchtower/config.bsc-testnet.json):
///   1. `redirect()`: an attacker with the stolen admin key schedules "cold wallet = mine" (the Watchtower cancels
///      it within seconds); also PREPARES, without sending, the attacker's attempt to execute it anyway and a
///      guardian's attempt to evacuate (deployments/bsc-testnet/epk-v2-evacuation.json) — send them with
///      scripts/v2/demo_attacks.py, so each rejection is recorded on-chain;
///   2. `evacuate()`: the owner's recovery key evacuates every tracked asset to the cold wallet registered at setup.
///   forge script scripts/v2/DemoEvacuation.s.sol:DemoEvacuation --sig "redirect()" --rpc-url $BSC_RPC_URL --broadcast
///   python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2-evacuation.json
///   forge script scripts/v2/DemoEvacuation.s.sol:DemoEvacuation --sig "evacuate()" --rpc-url $BSC_RPC_URL --broadcast
contract DemoEvacuation is Script {
    string internal constant IN_VAULT = "deployments/bsc-testnet/epk-v2-vault.json";
    string internal constant OUT = "deployments/bsc-testnet/epk-v2-evacuation.json";
    address internal constant ATTACKER = address(0xBAD2);
    bytes32 internal constant SALT = keccak256("EPK demo: stolen admin key redirects the cold wallet");

    function _vault() internal view returns (EPKVault) {
        require(block.chainid == 97, "BSC Testnet only");
        return EPKVault(payable(vm.parseJsonAddress(vm.readFile(IN_VAULT), ".vault")));
    }

    function redirect() external {
        EPKVault vault = _vault();
        bytes memory change = abi.encodeCall(IEPKVaultEmergency.setColdWallet, (ATTACKER));
        vm.broadcast(vm.envUint("PRIVATE_KEY")); // the stolen admin key
        bytes32 id = vault.schedule(change, SALT);
        console2.log("Attacker scheduled setColdWallet(0xBAD2); operation id:");
        console2.logBytes32(id);

        string memory o = "evacuation";
        vm.serializeAddress(o, "vault", address(vault));
        vm.serializeBytes32(o, "operationId", id);
        vm.serializeString(o, "h_executeColdWalletChange_from", "admin");
        vm.serializeBytes(o, "h_executeColdWalletChange", abi.encodeCall(EPKVault.executeScheduled, (change, SALT)));
        vm.serializeString(o, "i_guardianEvacuates_from", "guardian1");
        string memory json = vm.serializeBytes(
            o, "i_guardianEvacuates", abi.encodeCall(IEPKVaultEmergency.evacuate, (new address[](0)))
        );
        vm.writeJson(json, OUT);
    }

    function evacuate() external {
        EPKVault vault = _vault();
        vm.broadcast(vm.envUint("V2_RECOVERY_PRIVATE_KEY"));
        IEPKVaultEmergency(address(vault)).evacuate(new address[](0));
        console2.log("evacuated to the cold wallet:", vault.coldWallet());
        console2.log("vault paused:", vault.paused());
    }
}
