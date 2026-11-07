// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {EPKVault} from "../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../contracts/v2/EPKVaultFactory.sol";
import {EPKRegistry} from "../../contracts/v2/EPKRegistry.sol";
import {EPKTestUSD} from "./demo/EPKTestUSD.sol";
import {EPKVaultDemoRelease211} from "./demo/EPKVaultDemoRelease211.sol";
import {EPKVaultDemoRelease212} from "./demo/EPKVaultDemoRelease212.sol";

/// @title Full opt-in upgrade on BSC Testnet in minutes (test-network delays, same code as mainnet)
/// @notice A separate stack (the 2.0.x demo vault and the 2.1 guard demo vault are not touched):
///         registry + factory on EPKVault 2.1.0, a vault holding 10 tUSD, release 2.1.1 proposed and the
///         vault's upgrade scheduled in the same run — both clocks run in parallel (5 minutes each on test
///         networks). `execute()` finishes the upgrade at the same address with the same funds.
///   forge script scripts/v2/FastUpgradeDemo.s.sol:FastUpgradeDemo --sig "start()"   --rpc-url $BSC_RPC_URL --broadcast --slow
///   (wait 5 minutes)
///   forge script scripts/v2/FastUpgradeDemo.s.sol:FastUpgradeDemo --sig "execute()" --rpc-url $BSC_RPC_URL --broadcast
contract FastUpgradeDemo is Script {
    string internal constant OUT = "deployments/bsc-testnet/epk-v2.1-fast-upgrade.json";
    bytes32 internal constant SALT = keccak256("EPK fast test-network upgrade to 2.1.1");

    function start() external {
        require(block.chainid == 97, "BSC Testnet only");
        uint256 pk = vm.envUint("V21_ADMIN_PRIVATE_KEY");
        address admin = vm.addr(pk);
        address[] memory g = new address[](2);
        g[0] = vm.addr(vm.envUint("V21_GUARDIAN1_PRIVATE_KEY"));
        g[1] = vm.addr(vm.envUint("V21_GUARDIAN2_PRIVATE_KEY"));
        address recovery = vm.addr(vm.envUint("V21_RECOVERY_PRIVATE_KEY"));
        EPKTestUSD tusd = EPKTestUSD(vm.parseJsonAddress(vm.readFile("deployments/bsc-testnet/epk-v2.1.json"), ".tusd"));

        vm.startBroadcast(pk);
        EPKVault genesis = new EPKVault();
        EPKRegistry registry = new EPKRegistry(admin, address(genesis));
        EPKVaultFactory factory = new EPKVaultFactory(address(genesis), address(registry));
        EPKVault vault = EPKVault(payable(factory.createVault(g, 1 hours, recovery, keccak256("EPK fast upgrade demo"))));
        vault.setAsset(address(tusd), 5e18, 1 days, type(uint128).max);
        vault.finalizeSetup();
        tusd.mint(address(vault), 10e18);

        EPKVaultDemoRelease211 release = new EPKVaultDemoRelease211();
        registry.proposeRelease(address(release));
        bytes32 id = vault.scheduleUpgrade(address(release), SALT); // in parallel with the release window
        vm.stopBroadcast();

        string memory o = "fast";
        vm.serializeAddress(o, "genesis_2_1_0", address(genesis));
        vm.serializeAddress(o, "registry", address(registry));
        vm.serializeAddress(o, "factory", address(factory));
        vm.serializeAddress(o, "vault", address(vault));
        vm.serializeAddress(o, "release_2_1_1", address(release));
        vm.serializeAddress(o, "token", address(tusd));
        vm.serializeBytes32(o, "operationId", id);
        vm.serializeUint(o, "registryApprovalDelay", registry.approvalDelay());
        string memory out = vm.serializeUint(o, "createdAtBlock", block.number);
        vm.writeJson(out, OUT);
        console2.log("vault:", address(vault));
        console2.log("release 2.1.1:", address(release));
        console2.log("release window (s):", registry.approvalDelay());
    }

    /// @notice Registry owner publishes release 2.1.2 for the same vault; the vault's admin then schedules and
    ///         executes the upgrade with SDK v2 (sdk/examples/v2-upgrade.ts).
    function proposeNext() external {
        string memory j = vm.readFile(OUT);
        EPKRegistry registry = EPKRegistry(vm.parseJsonAddress(j, ".registry"));
        vm.startBroadcast(vm.envUint("V21_ADMIN_PRIVATE_KEY"));
        EPKVaultDemoRelease212 release = new EPKVaultDemoRelease212();
        registry.proposeRelease(address(release));
        vm.stopBroadcast();
        vm.writeJson(vm.toString(address(release)), OUT, ".release_2_1_2");
        console2.log("release 2.1.2:", address(release));
    }

    function execute() external {
        string memory j = vm.readFile(OUT);
        EPKVault vault = EPKVault(payable(vm.parseJsonAddress(j, ".vault")));
        address release = vm.parseJsonAddress(j, ".release_2_1_1");
        EPKTestUSD tusd = EPKTestUSD(vm.parseJsonAddress(j, ".token"));
        uint256 before = tusd.balanceOf(address(vault));
        vm.startBroadcast(vm.envUint("V21_ADMIN_PRIVATE_KEY"));
        vault.executeScheduled(vault.upgradeOperationData(release), SALT);
        vm.stopBroadcast();
        require(vault.vaultVersion() == 20_101, "not upgraded");
        require(tusd.balanceOf(address(vault)) == before, "funds changed");
        console2.log("vault", address(vault), "now runs version", vault.vaultVersion());
        console2.log("tUSD in the vault before / after:", before, tusd.balanceOf(address(vault)));
    }
}
