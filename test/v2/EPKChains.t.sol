// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {EPKVault} from "../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../contracts/v2/EPKVaultFactory.sol";
import {EPKRegistry} from "../../contracts/v2/EPKRegistry.sol";
import {EPKVaultV21} from "./EPKVault.upgrade.t.sol";

/// Same code, different networks: production delays everywhere except public test networks, where a full
/// release -> schedule -> upgrade cycle takes minutes. Both clocks (release window, vault wait) run in parallel.
contract EPKChainsTest is Test {
    address admin = makeAddr("admin");
    address registryOwner = makeAddr("registryOwner");
    address recoveryKey = makeAddr("recovery");

    EPKRegistry registry;
    EPKVault vault;
    EPKVaultV21 next;

    function _deploy(uint256 chainId, uint256 vaultDelay) internal {
        vm.chainId(chainId);
        EPKVault genesis = new EPKVault();
        next = new EPKVaultV21();
        registry = new EPKRegistry(registryOwner, address(genesis));
        EPKVaultFactory factory = new EPKVaultFactory(address(genesis), address(registry));
        address[] memory g = new address[](2);
        g[0] = makeAddr("g1");
        g[1] = makeAddr("g2");
        vm.prank(admin);
        vault = EPKVault(payable(factory.createVault(g, vaultDelay, recoveryKey, bytes32("c"))));
        vm.prank(admin);
        vault.finalizeSetup();
    }

    function _impl() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(vault), bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)))));
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    /// BSC Testnet: release window 5 minutes, upgrade wait 5 minutes, running at the same time.
    function test_testnet_fullUpgradeCycleInFiveMinutes() public {
        _deploy(97, 1 hours);
        assertEq(registry.approvalDelay(), 5 minutes);

        vm.prank(registryOwner);
        registry.proposeRelease(address(next));
        bytes memory op = vault.upgradeOperationData(address(next));
        vm.prank(admin);
        vault.scheduleUpgrade(address(next), bytes32("fast"));

        vm.warp(_now() + 5 minutes - 1);
        vm.prank(admin);
        vm.expectRevert(EPKVault.OperationNotReady.selector);
        vault.executeScheduled(op, bytes32("fast"));

        vm.warp(_now() + 1);
        vm.prank(admin);
        vault.executeScheduled(op, bytes32("fast"));
        assertEq(_impl(), address(next));
        assertEq(vault.vaultVersion(), 20_300);
    }

    /// On test networks guardians can still veto, and an unlisted implementation is still refused.
    function test_testnet_sameProtectionsJustFaster() public {
        _deploy(97, 1 hours);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.ImplementationNotApproved.selector, address(next)));
        vault.scheduleUpgrade(address(next), bytes32(0)); // not listed in the registry

        vm.prank(registryOwner);
        registry.proposeRelease(address(next));
        vm.prank(admin);
        bytes32 id = vault.scheduleUpgrade(address(next), bytes32(0));
        vm.prank(makeAddr("g1"));
        vault.cancel(id);
        vm.warp(_now() + 10 minutes);
        bytes memory op = vault.upgradeOperationData(address(next));
        vm.prank(admin);
        vm.expectRevert(EPKVault.UnknownOperation.selector);
        vault.executeScheduled(op, bytes32(0));
    }

    /// Mainnets (and unknown chains) keep the production rules: 7-day release window, 2-day upgrade
    /// floor, 1-hour minimum timelock. Local test chains too, so the test suite exercises the real rules.
    function test_productionRulesOnMainnetsAndLocalChains() public {
        uint256[4] memory chains = [uint256(56), 1, 8453, 31337];
        for (uint256 i = 0; i < chains.length; i++) {
            vm.chainId(chains[i]);
            EPKVault genesis = new EPKVault();
            EPKRegistry r = new EPKRegistry(registryOwner, address(genesis));
            assertEq(r.approvalDelay(), 7 days);
            EPKVaultFactory f = new EPKVaultFactory(address(genesis), address(r));
            address[] memory g = new address[](2);
            g[0] = makeAddr("g1");
            g[1] = makeAddr("g2");
            vm.prank(admin);
            vm.expectRevert(EPKVault.BadDelay.selector);
            f.createVault(g, 59 minutes, recoveryKey, bytes32(i));
        }
    }

    /// On a mainnet both clocks still run in parallel: the vault's 2-day wait passes during the 7-day
    /// release window, so the total is 7 days, not 9 — and the code still only runs once approved.
    function test_mainnet_parallelClocksSevenDaysNotNine() public {
        _deploy(56, 1 hours);
        vm.prank(registryOwner);
        registry.proposeRelease(address(next));
        bytes memory op = vault.upgradeOperationData(address(next));
        vm.prank(admin);
        vault.scheduleUpgrade(address(next), bytes32("p"));

        vm.warp(_now() + 2 days); // vault wait over, release window not
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.ImplementationNotApproved.selector, address(next)));
        vault.executeScheduled(op, bytes32("p"));

        vm.warp(_now() + 5 days); // day 7: approved
        vm.prank(admin);
        vault.executeScheduled(op, bytes32("p"));
        assertEq(_impl(), address(next));
    }

    /// A release revoked during its window can never run, even if a vault scheduled it early.
    function test_mainnet_revokedWhileScheduledNeverRuns() public {
        _deploy(56, 1 hours);
        vm.prank(registryOwner);
        registry.proposeRelease(address(next));
        vm.prank(admin);
        vault.scheduleUpgrade(address(next), bytes32("r"));
        vm.prank(registryOwner);
        registry.revokeRelease(address(next));
        vm.warp(_now() + 8 days);
        bytes memory op = vault.upgradeOperationData(address(next));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.ImplementationNotApproved.selector, address(next)));
        vault.executeScheduled(op, bytes32("r"));
    }
}
