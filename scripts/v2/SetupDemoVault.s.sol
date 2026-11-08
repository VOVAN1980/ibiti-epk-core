// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EPKVault, IEPKVaultEmergency} from "../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../contracts/v2/EPKVaultFactory.sol";
import {EPKDemoToken} from "./demo/EPKDemoToken.sol";

/// @title Step 2 — create and configure the demo vault (BSC testnet)
/// @notice Admin = deployer. Guardians, recovery and session manager come from .env (V2_*).
///         Vault-wide limit 1000 eUSD/day; each agent session gets 100 eUSD/day; only the owner's
///         treasury (the admin address) is an allowed destination. Funds the vault with demo tokens
///         and gives the role keys a little tBNB for gas.
/// forge script scripts/v2/SetupDemoVault.s.sol:SetupDemoVault --rpc-url $BSC_RPC_URL --broadcast
contract SetupDemoVault is Script {
    string internal constant IN = "deployments/bsc-testnet/epk-v2.json";
    string internal constant OUT = "deployments/bsc-testnet/epk-v2-vault.json";
    uint256 internal constant ENVELOPE = 1;

    function run() external {
        // EPK is not audited: these scripts refuse to run on any mainnet
        require(block.chainid == 97 || block.chainid == 11155111 || block.chainid == 31337, "EPK: test networks only");
        uint256 adminPk = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(adminPk);
        address g1 = vm.addr(vm.envUint("V2_GUARDIAN1_PRIVATE_KEY"));
        address g2 = vm.addr(vm.envUint("V2_GUARDIAN2_PRIVATE_KEY"));
        address recovery = vm.addr(vm.envUint("V2_RECOVERY_PRIVATE_KEY"));
        address manager = vm.addr(vm.envUint("V2_SESSION_MANAGER_PRIVATE_KEY"));
        address agent = vm.addr(vm.envUint("V2_AGENT_PRIVATE_KEY"));
        // the owner's cold wallet: a separate key that runs no role in the vault (evacuation goes only there)
        address cold = vm.addr(vm.envUint("V21_INTEGRATOR_PRIVATE_KEY"));
        // test networks allow a 5-minute timelock (vault 2.3.0+), so panic -> unpause takes minutes
        uint256 delay = vm.envOr("V2_DELAY", uint256(5 minutes));

        string memory json = vm.readFile(IN);
        EPKVaultFactory factory = EPKVaultFactory(vm.parseJsonAddress(json, ".factory"));
        EPKDemoToken token = EPKDemoToken(vm.parseJsonAddress(json, ".token"));

        address[] memory guardians = new address[](2);
        guardians[0] = g1;
        guardians[1] = g2;

        vm.startBroadcast(adminPk);
        EPKVault vault =
            EPKVault(payable(factory.createVault(guardians, delay, recovery, keccak256(abi.encode("EPK demo vault", block.number)))));

        // setup phase: the admin configures directly; afterwards loosening needs the timelock
        vault.setAsset(address(token), 1_000e18, 1 days, type(uint128).max);
        vault.setAsset(address(0), 0.01 ether, 1 days, type(uint128).max);
        vault.addDestination(admin); // the owner's treasury
        vault.setSessionManager(manager);
        vault.setEnvelope(ENVELOPE, true, 7 days, 0);
        vault.setEnvelopeCall(ENVELOPE, address(token), IERC20.transfer.selector, true);
        vault.setEnvelopeBudgetCap(ENVELOPE, address(token), 100e18);
        IEPKVaultEmergency(address(vault)).setColdWallet(cold);
        vault.finalizeSetup();

        token.mint(address(vault), 10_000e18);
        // gas money for the role keys that will act in the demo
        payable(g1).transfer(0.003 ether);
        payable(g2).transfer(0.002 ether);
        payable(manager).transfer(0.003 ether);
        payable(recovery).transfer(0.002 ether);
        vm.stopBroadcast();

        string memory o = "vault";
        vm.serializeAddress(o, "vault", address(vault));
        vm.serializeAddress(o, "admin", admin);
        vm.serializeAddress(o, "guardian1", g1);
        vm.serializeAddress(o, "guardian2", g2);
        vm.serializeAddress(o, "recovery", recovery);
        vm.serializeAddress(o, "sessionManager", manager);
        vm.serializeAddress(o, "agent", agent);
        vm.serializeAddress(o, "coldWallet", cold);
        vm.serializeUint(o, "delay", delay);
        string memory out = vm.serializeUint(o, "envelope", ENVELOPE);
        vm.writeJson(out, OUT);

        console2.log("Demo vault:", address(vault));
        console2.log("Vault eUSD balance:", token.balanceOf(address(vault)) / 1e18);
        console2.log("Available today (eUSD):", vault.availableToSpend(address(token)) / 1e18);
    }
}
