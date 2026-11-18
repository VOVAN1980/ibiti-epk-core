// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {EPKVault} from "../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../contracts/v2/EPKVaultFactory.sol";
import {EPKRegistry} from "../../contracts/v2/EPKRegistry.sol";

/// A patch release of 2.3.0 (2.3.1): no new storage, nothing to migrate.
contract EPKVault231 is EPKVault {
    function vaultVersion() public pure override returns (uint64) {
        return 20_301;
    }

    function _migrate(uint64) internal override reinitializer(2) {}
}

/// A minor release (2.4.0): never eligible for the fast track.
contract EPKVault240 is EPKVault {
    function vaultVersion() public pure override returns (uint64) {
        return 20_400;
    }

    function _migrate(uint64) internal override reinitializer(2) {}
}

/// Fast track for urgent security fixes: an independent security council may make an already-proposed
/// PATCH release usable at once. The registry owner (IBITI) alone cannot skip the public window, the
/// council alone cannot list code, and every vault still opts in through its own upgrade wait, which
/// its guardians can veto. Local chain 31337 runs the production rules (7-day window, 2-day upgrade floor).
contract EPKRegistryFastTrackTest is Test {
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 constant DELAY = 1 hours; // the vault's own timelock (production minimum)

    EPKVault genesis;
    EPKVault231 patch;
    EPKVault240 minor;
    EPKRegistry registry;
    EPKVaultFactory factory;
    EPKVault vault;

    address ibiti = makeAddr("ibiti"); // registry owner
    address council = makeAddr("council"); // the security council's multisig
    address admin = makeAddr("admin"); // the vault owner
    address guardian = makeAddr("guardian");
    address guardian2 = makeAddr("guardian2");
    address recoveryKey = makeAddr("recovery");
    address stranger = makeAddr("stranger");

    function setUp() public {
        _deploy(council);
    }

    function _deploy(address council_) internal {
        genesis = new EPKVault();
        patch = new EPKVault231();
        minor = new EPKVault240();
        registry = new EPKRegistry(ibiti, address(genesis), council_);
        factory = new EPKVaultFactory(address(genesis), address(registry));
        address[] memory g = new address[](2);
        g[0] = guardian;
        g[1] = guardian2;
        vm.prank(admin);
        vault = EPKVault(payable(factory.createVault(g, DELAY, recoveryKey, bytes32("ft"))));
        vm.prank(admin);
        vault.finalizeSetup();
    }

    function _propose(address impl) internal {
        vm.prank(ibiti);
        registry.proposeRelease(impl);
    }

    function _impl() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(vault), IMPL_SLOT))));
    }

    // ---------------------------------------------------------------- who may do what

    function test_councilMakesAProposedPatchUsableAtOnce() public {
        _propose(address(patch));
        assertFalse(registry.isApproved(address(patch)), "still in its 7-day window");

        vm.expectEmit(address(registry));
        emit EPKRegistry.ReleaseFastTracked(address(patch), 20_301);
        vm.prank(council);
        registry.fastTrack(address(patch));

        assertTrue(registry.isApproved(address(patch)));
        (, uint64 activeAt,,) = registry.releases(address(patch));
        assertEq(activeAt, block.timestamp);
    }

    function test_ownerAloneCannotSkipTheWindow() public {
        _propose(address(patch));
        vm.prank(ibiti);
        vm.expectRevert(EPKRegistry.NotCouncil.selector);
        registry.fastTrack(address(patch));
    }

    function test_strangerCannotFastTrack() public {
        _propose(address(patch));
        vm.prank(stranger);
        vm.expectRevert(EPKRegistry.NotCouncil.selector);
        registry.fastTrack(address(patch));
    }

    function test_councilCannotListCode() public {
        vm.prank(council);
        vm.expectRevert(EPKRegistry.NotOwner.selector);
        registry.proposeRelease(address(patch));
    }

    function test_unlistedCodeCannotBeFastTracked() public {
        vm.prank(council);
        vm.expectRevert(abi.encodeWithSelector(EPKRegistry.UnknownRelease.selector, address(patch)));
        registry.fastTrack(address(patch));
    }

    function test_onlyPatchReleases() public {
        _propose(address(minor));
        vm.prank(council);
        vm.expectRevert(abi.encodeWithSelector(EPKRegistry.NotAPatch.selector, uint64(20_300), uint64(20_400)));
        registry.fastTrack(address(minor));
        assertFalse(registry.isApproved(address(minor)), "a minor release keeps its full window");
    }

    function test_revokedReleaseCannotBeFastTracked() public {
        _propose(address(patch));
        vm.prank(ibiti);
        registry.revokeRelease(address(patch));
        vm.prank(council);
        vm.expectRevert(abi.encodeWithSelector(EPKRegistry.NotPending.selector, address(patch)));
        registry.fastTrack(address(patch));
    }

    function test_activeReleaseHasNothingToFastTrack() public {
        _propose(address(patch));
        vm.warp(block.timestamp + registry.APPROVAL_DELAY());
        vm.prank(council);
        vm.expectRevert(abi.encodeWithSelector(EPKRegistry.NotPending.selector, address(patch)));
        registry.fastTrack(address(patch));
    }

    function test_noCouncilNoFastTrack() public {
        _deploy(address(0));
        _propose(address(patch));
        vm.prank(address(0));
        vm.expectRevert(EPKRegistry.NotCouncil.selector);
        registry.fastTrack(address(patch));
        vm.prank(address(0));
        vm.expectRevert(EPKRegistry.NotOwnerOrCouncil.selector);
        registry.revokeRelease(address(patch));
    }

    /// If the owner's key is stolen and used to propose bad code, the council stops it at once.
    function test_councilCanRevokeInstantly() public {
        _propose(address(patch));
        vm.prank(council);
        registry.revokeRelease(address(patch));
        vm.warp(block.timestamp + registry.APPROVAL_DELAY());
        assertFalse(registry.isApproved(address(patch)));

        vm.prank(stranger);
        vm.expectRevert(EPKRegistry.NotOwnerOrCouncil.selector);
        registry.revokeRelease(address(genesis));
    }

    // ---------------------------------------------------------------- the vault still decides

    function test_vaultStillWaitsItsOwnUpgradeDelay() public {
        _propose(address(patch));
        vm.prank(council);
        registry.fastTrack(address(patch));

        bytes memory op = vault.upgradeOperationData(address(patch));
        vm.prank(admin);
        vault.scheduleUpgrade(address(patch), bytes32(0));

        // production floor: at least 2 days, even for a fast-tracked fix
        vm.warp(block.timestamp + 2 days - 1);
        vm.prank(admin);
        vm.expectRevert(EPKVault.OperationNotReady.selector);
        vault.executeScheduled(op, bytes32(0));

        vm.warp(block.timestamp + 1);
        vm.prank(admin);
        vault.executeScheduled(op, bytes32(0));
        assertEq(_impl(), address(patch));
        assertEq(vault.vaultVersion(), 20_301);
    }

    function test_guardianCanStillVetoAFastTrackedUpgrade() public {
        _propose(address(patch));
        vm.prank(council);
        registry.fastTrack(address(patch));

        bytes memory op = vault.upgradeOperationData(address(patch));
        vm.prank(admin);
        bytes32 id = vault.scheduleUpgrade(address(patch), bytes32(0));
        vm.prank(guardian);
        vault.cancel(id);

        vm.warp(block.timestamp + 2 days);
        vm.prank(admin);
        vm.expectRevert(EPKVault.UnknownOperation.selector);
        vault.executeScheduled(op, bytes32(0));
        assertEq(_impl(), address(genesis));
    }

    function test_nobodyButTheVaultOwnerCanStartTheUpgrade() public {
        _propose(address(patch));
        vm.prank(council);
        registry.fastTrack(address(patch));
        address[3] memory others = [ibiti, council, stranger];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(others[i]);
            vm.expectRevert(EPKVault.NotAdmin.selector);
            vault.scheduleUpgrade(address(patch), bytes32(0));
        }
    }

    // ---------------------------------------------------------------- public test networks

    /// On BSC Testnet the window is 5 minutes and so is the vault's upgrade wait: the fast track changes
    /// the window only, and the whole cycle still takes about 5 minutes.
    function test_onTestNetworksTheCycleStaysAboutFiveMinutes() public {
        vm.chainId(97);
        _deploy(council);
        assertEq(registry.approvalDelay(), 5 minutes);
        _propose(address(patch));
        vm.prank(council);
        registry.fastTrack(address(patch));
        assertTrue(registry.isApproved(address(patch)));

        bytes memory op = vault.upgradeOperationData(address(patch));
        vm.prank(admin);
        vault.scheduleUpgrade(address(patch), bytes32(0));
        vm.warp(block.timestamp + 5 minutes);
        vm.prank(admin);
        vault.executeScheduled(op, bytes32(0));
        assertEq(vault.vaultVersion(), 20_301);
    }
}
