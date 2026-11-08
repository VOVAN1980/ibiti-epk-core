// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {EPKVault} from "../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../contracts/v2/EPKVaultFactory.sol";
import {EPKRegistry} from "../../contracts/v2/EPKRegistry.sol";
import {TestToken} from "./V2Mocks.sol";

/// A future release: new feature + appended storage + one-time migration.
contract EPKVaultV21 is EPKVault {
    uint256 public newSetting; // appended after all v2.3.0 storage

    function vaultVersion() public pure virtual override returns (uint64) {
        return 20_400; // 2.4.0
    }

    function _migrate(uint64 from) internal virtual override reinitializer(2) {
        if (from < 2) newSetting = 42;
    }

    function hello() external pure returns (string memory) {
        return "2.1";
    }
}

/// The release after it: migrates cumulatively, so vaults that skipped 2.4.0 still get its step.
contract EPKVaultV22 is EPKVaultV21 {
    uint256 public v22Setting;

    function vaultVersion() public pure override returns (uint64) {
        return 20_500; // 2.5.0
    }

    function _migrate(uint64 from) internal override reinitializer(3) {
        if (from < 2) newSetting = 42; // 2.4.0 step
        if (from < 3) v22Setting = 7; // 2.5.0 step
    }
}

/// A release whose author forgot the migration: it can never be installed.
contract NoMigrationVault is EPKVault {
    function vaultVersion() public pure override returns (uint64) {
        return 20_400;
    }
}

/// Stand-in for the 2.1.0 implementation deployed on BSC Testnet: its version, and its migration that
/// refused (nothing could upgrade TO 2.1.0 itself).
contract EPKVault210 is EPKVault {
    function vaultVersion() public pure override returns (uint64) {
        return 20_100;
    }

    function _migrate(uint64) internal pure override {
        revert BadOperation();
    }
}

/// What an attacker would like to install.
contract MaliciousVault is EPKVault {
    function vaultVersion() public pure override returns (uint64) {
        return 20_500;
    }

    function drain(address token, address to) external {
        IERC20(token).transfer(to, IERC20(token).balanceOf(address(this)));
    }
}

/// Release that claims a far-future version (would exhaust the version space).
contract FarFutureVault is EPKVault {
    function vaultVersion() public pure override returns (uint64) {
        return 90_000;
    }
}

/// Pays with the 2300-gas stipend, like many payout contracts.
contract StipendPayer {
    function pay(address payable to) external payable {
        to.transfer(msg.value);
    }
}

abstract contract UpgradeBase is Test {
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 constant DELAY = 1 days;

    EPKVault genesis;
    EPKVaultV21 v21;
    MaliciousVault evil;
    EPKRegistry registry;
    EPKVaultFactory factory;
    EPKVault vault;
    TestToken token;

    address registryOwner = makeAddr("registryOwner");
    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address guardian2 = makeAddr("guardian2");
    address recoveryKey = makeAddr("recovery");
    address agent = makeAddr("agent");
    address friend = makeAddr("friend");
    address attacker = makeAddr("attacker");
    uint256 signerPk = 0x51;
    uint256 pid;

    function _deployAll() internal {
        genesis = new EPKVault();
        v21 = new EPKVaultV21();
        evil = new MaliciousVault();
        registry = new EPKRegistry(registryOwner, address(genesis));
        factory = new EPKVaultFactory(address(genesis), address(registry));
        token = new TestToken("TKN");

        address[] memory g = new address[](2);
        g[0] = guardian;
        g[1] = guardian2;
        vm.prank(admin);
        vault = EPKVault(payable(factory.createVault(g, DELAY, recoveryKey, bytes32("u"))));

        vm.startPrank(admin);
        vault.setAsset(address(token), 100e18, 1 days, type(uint128).max);
        vault.addDestination(friend);
        pid = vault.createPolicy(vm.addr(signerPk), 0, 0, address(0));
        vault.setAgent(pid, agent, true, 0);
        vault.setCall(pid, address(token), IERC20.transfer.selector, true);
        vault.finalizeSetup();
        vm.stopPrank();

        token.mint(address(vault), 1_000e18);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _warp(uint256 secs) internal {
        vm.warp(_now() + secs);
    }

    function _impl() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(vault), IMPL_SLOT))));
    }

    function _list(address impl) internal {
        vm.prank(registryOwner);
        registry.proposeRelease(impl);
        _warp(registry.APPROVAL_DELAY());
    }

    function _listV21() internal {
        _list(address(v21));
    }

    /// @dev Built locally (no external call), so vm.prank / expectRevert hit the intended call.
    function _op(address impl) internal pure returns (bytes memory) {
        return abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (impl, abi.encodeCall(EPKVault.migrate, ())));
    }

    function _upgradeTo(address impl) internal {
        vm.prank(admin);
        vault.scheduleUpgrade(impl, bytes32(0));
        _warp(2 * DELAY);
        vm.prank(admin);
        vault.executeScheduled(_op(impl), bytes32(0));
    }

    function _upgradeV21() internal {
        _upgradeTo(address(v21));
    }

    function _transferOnce(uint256 amount) internal {
        EPKVault.Call[] memory calls = new EPKVault.Call[](1);
        calls[0] = EPKVault.Call(address(token), 0, abi.encodeCall(IERC20.transfer, (friend, amount)));
        uint256 deadline = _now() + 1 hours;
        bytes32 d = vault.getExecuteDigest(pid, agent, calls, vault.nonces(pid), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, d);
        vm.prank(agent);
        vault.execute(pid, calls, deadline, abi.encodePacked(r, s, v), "");
    }
}

contract EPKVaultUpgradeTest is UpgradeBase {
    function setUp() public {
        _deployAll();
    }

    function test_upgradeOperationDataMatchesHelper() public view {
        assertEq(vault.upgradeOperationData(address(v21)), _op(address(v21)));
    }

    function test_vaultIsProxyOnGenesis() public view {
        assertEq(_impl(), address(genesis));
        assertEq(vault.vaultVersion(), 20_300);
        assertEq(vault.registry(), address(registry));
        assertEq(registry.versionOf(address(genesis)), 20_300);
    }

    function test_upgradeKeepsAddressFundsAndSettings() public {
        _transferOnce(10e18);
        _listV21();
        _upgradeV21();

        // same address, new code, migrated state
        assertEq(_impl(), address(v21));
        assertEq(vault.vaultVersion(), 20_400);
        assertEq(EPKVaultV21(payable(address(vault))).hello(), "2.1");
        assertEq(EPKVaultV21(payable(address(vault))).newSetting(), 42);

        // nothing lost
        assertEq(token.balanceOf(address(vault)), 990e18);
        assertEq(vault.admin(), admin);
        assertTrue(vault.isGuardian(guardian) && vault.isGuardian(guardian2));
        assertTrue(vault.isDestination(friend));
        assertEq(vault.nonces(pid), 1);

        // existing policy keeps working, the kill switch keeps working
        _transferOnce(5e18);
        assertEq(token.balanceOf(friend), 15e18);
        vm.prank(guardian);
        vault.panic();
        assertTrue(vault.paused());
    }

    /// Review round 2 F2 / round 3 L-3: nobody but the vault can run a migration, on any release.
    function test_migrationOnlyByTheVaultItself() public {
        vm.prank(attacker);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        vault.migrate();

        _listV21();
        _upgradeV21();
        vm.prank(attacker);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        vault.migrate();

        vm.prank(admin);
        vm.expectRevert(EPKVault.BadOperation.selector); // and not through the generic timelock either
        vault.schedule(abi.encodeCall(EPKVault.migrate, ()), bytes32(0));
    }

    /// Review round 3 M-1: a vault that skips a release still gets that release's migration step.
    function test_skippedReleaseMigrationStillRuns() public {
        EPKVaultV22 v22 = new EPKVaultV22();
        _listV21();
        _list(address(v22));

        _upgradeTo(address(v22)); // 2.3.0 -> 2.5.0 directly
        assertEq(vault.vaultVersion(), 20_500);
        assertEq(EPKVaultV22(payable(address(vault))).newSetting(), 42);
        assertEq(EPKVaultV22(payable(address(vault))).v22Setting(), 7);
    }

    function test_stepByStepMigrationRunsEachStepOnce() public {
        EPKVaultV22 v22 = new EPKVaultV22();
        _listV21();
        _list(address(v22));
        _upgradeV21();
        _upgradeTo(address(v22));
        assertEq(EPKVaultV22(payable(address(vault))).newSetting(), 42);
        assertEq(EPKVaultV22(payable(address(vault))).v22Setting(), 7);
    }

    function test_releaseWithoutMigrationCannotBeInstalled() public {
        NoMigrationVault lazy = new NoMigrationVault();
        _list(address(lazy));
        vm.prank(admin);
        vault.scheduleUpgrade(address(lazy), bytes32(0));
        _warp(2 * DELAY);
        vm.prank(admin);
        vm.expectRevert(EPKVault.BadOperation.selector);
        vault.executeScheduled(_op(address(lazy)), bytes32(0));
        assertEq(_impl(), address(genesis));
    }

    /// Review round 3 L-1: ordinary operations scheduled under one release do not run under the next;
    /// recovery operations survive the upgrade.
    function test_pendingOperationsGoStaleAfterUpgrade() public {
        _listV21();
        bytes memory addDest = abi.encodeCall(EPKVault.addDestination, (attacker));
        vm.prank(admin);
        vault.schedule(addDest, bytes32(0));
        vm.prank(recoveryKey);
        vault.recoverAdmin(makeAddr("newAdmin"), bytes32(0));

        _upgradeV21();

        vm.prank(admin);
        vm.expectRevert(EPKVault.StaleOperation.selector);
        vault.executeScheduled(addDest, bytes32(0));

        vm.prank(recoveryKey);
        vault.executeScheduled(abi.encodeCall(EPKVault.setAdmin, (makeAddr("newAdmin"))), bytes32(0));
        assertEq(vault.admin(), makeAddr("newAdmin"));
    }

    function test_upgradeNeedsTwiceTheDelay() public {
        _listV21();
        vm.prank(admin);
        vault.scheduleUpgrade(address(v21), bytes32(0));
        _warp(DELAY);
        vm.prank(admin);
        vm.expectRevert(EPKVault.OperationNotReady.selector);
        vault.executeScheduled(_op(address(v21)), bytes32(0));
        _warp(DELAY);
        vm.prank(admin);
        vault.executeScheduled(_op(address(v21)), bytes32(0));
        assertEq(_impl(), address(v21));
    }

    /// Review round 2 F5: lowering the vault delay first does not make upgrades faster than the floor.
    function test_upgradeDelayFloorAfterLoweringDelay() public {
        bytes memory lower = abi.encodeCall(EPKVault.setDelay, (1 hours));
        vm.prank(admin);
        vault.schedule(lower, bytes32(0));
        _warp(DELAY);
        vm.prank(admin);
        vault.executeScheduled(lower, bytes32(0));
        assertEq(vault.delay(), 1 hours);

        _listV21();
        vm.prank(admin);
        vault.scheduleUpgrade(address(v21), bytes32(0));
        _warp(2 hours);
        vm.prank(admin);
        vm.expectRevert(EPKVault.OperationNotReady.selector);
        vault.executeScheduled(_op(address(v21)), bytes32(0));
        _warp(vault.UPGRADE_DELAY_FLOOR() - 2 hours);
        vm.prank(admin);
        vault.executeScheduled(_op(address(v21)), bytes32(0));
        assertEq(_impl(), address(v21));
    }

    function test_noDirectOrGenericUpgradePath() public {
        _listV21();
        address[5] memory callers = [admin, guardian, attacker, address(registry), recoveryKey];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(EPKVault.NotTimelocked.selector);
            vault.upgradeToAndCall(address(v21), "");
        }
        vm.prank(admin);
        vm.expectRevert(EPKVault.BadOperation.selector);
        vault.schedule(_op(address(v21)), bytes32(0));

        vm.prank(admin);
        vm.expectRevert(EPKVault.UnknownOperation.selector);
        vault.executeScheduled(_op(address(v21)), bytes32(0));
        assertEq(_impl(), address(genesis));
    }

    function test_compromisedAdminCannotInstallUnapprovedCode() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.ImplementationNotApproved.selector, address(evil)));
        vault.scheduleUpgrade(address(evil), bytes32(0));
        assertEq(_impl(), address(genesis));
    }

    /// Both clocks run in parallel: a vault may schedule during the release window, but the new code can
    /// only run once the registry approves it.
    function test_releaseUsableOnlyAfterRegistryDelay() public {
        vm.prank(registryOwner);
        registry.proposeRelease(address(v21));
        vm.prank(admin);
        vault.scheduleUpgrade(address(v21), bytes32(0));
        _warp(registry.APPROVAL_DELAY() - 1); // the vault's own wait is long over
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.ImplementationNotApproved.selector, address(v21)));
        vault.executeScheduled(_op(address(v21)), bytes32(0));
        _warp(1);
        vm.prank(admin);
        vault.executeScheduled(_op(address(v21)), bytes32(0));
        assertEq(_impl(), address(v21));
    }

    function test_revokedReleaseCannotBeInstalled() public {
        _listV21();
        vm.prank(admin);
        vault.scheduleUpgrade(address(v21), bytes32(0));
        vm.prank(registryOwner);
        registry.revokeRelease(address(v21));
        _warp(2 * DELAY);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.ImplementationNotApproved.selector, address(v21)));
        vault.executeScheduled(_op(address(v21)), bytes32(0));
        assertEq(_impl(), address(genesis));
    }

    function test_noDowngrade() public {
        _listV21();
        _upgradeV21();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.NotNewerVersion.selector, 20_400, 20_300));
        vault.scheduleUpgrade(address(genesis), bytes32(0));
    }

    function test_guardianVetoAndPanicStopUpgrades() public {
        _listV21();
        vm.prank(admin);
        bytes32 id = vault.scheduleUpgrade(address(v21), bytes32("a"));
        vm.prank(guardian);
        vault.cancel(id);

        vm.prank(admin);
        vault.scheduleUpgrade(address(v21), bytes32("b"));
        vm.prank(guardian2);
        vault.panic();

        _warp(2 * DELAY);
        vm.startPrank(admin);
        vm.expectRevert(EPKVault.UnknownOperation.selector);
        vault.executeScheduled(_op(address(v21)), bytes32("a"));
        vm.expectRevert(EPKVault.StaleOperation.selector);
        vault.executeScheduled(_op(address(v21)), bytes32("b"));
        vm.stopPrank();
        assertEq(_impl(), address(genesis));
    }

    /// Review round 3 M-2: with one guardian absent, the recovery key can still veto a compromised
    /// admin replacing the honest guardian (which that guardian itself cannot cancel).
    function test_recoveryVetoesGuardianReplacementWhenAGuardianIsAbsent() public {
        bytes memory replace = abi.encodeCall(EPKVault.replaceGuardian, (guardian, attacker));
        vm.prank(admin);
        bytes32 id = vault.schedule(replace, bytes32(0));
        vm.prank(guardian);
        vm.expectRevert(EPKVault.CannotCancel.selector);
        vault.cancel(id);
        vm.prank(recoveryKey);
        vault.cancel(id);
        _warp(DELAY);
        vm.prank(admin);
        vm.expectRevert(EPKVault.UnknownOperation.selector);
        vault.executeScheduled(replace, bytes32(0));
        assertTrue(vault.isGuardian(guardian));
    }

    /// Review round 3 L-2: a compromised admin cannot squat the recovery operation's id.
    function test_recoveryReplacesSquattedOperation() public {
        address newAdmin = makeAddr("newAdmin");
        bytes memory op = abi.encodeCall(EPKVault.setAdmin, (newAdmin));
        vm.prank(admin);
        vault.schedule(op, bytes32("s")); // squat
        vm.prank(recoveryKey);
        bytes32 id = vault.recoverAdmin(newAdmin, bytes32("s")); // replaces it
        vm.prank(admin);
        vm.expectRevert(EPKVault.CannotCancel.selector);
        vault.cancel(id);
        vm.prank(admin);
        vm.expectRevert(EPKVault.OperationExists.selector); // and cannot squat it back
        vault.schedule(op, bytes32("s"));
        _warp(2 * DELAY);
        vm.prank(recoveryKey);
        vault.executeScheduled(op, bytes32("s"));
        assertEq(vault.admin(), newAdmin);
    }

    /// Review I7: the recovery key can only execute its own recovery operations.
    function test_recoveryCannotExecuteAdminOperations() public {
        _listV21();
        vm.prank(admin);
        vault.scheduleUpgrade(address(v21), bytes32(0));
        _warp(2 * DELAY);
        vm.prank(recoveryKey);
        vm.expectRevert(EPKVault.NotAdminOrRecovery.selector);
        vault.executeScheduled(_op(address(v21)), bytes32(0));
    }

    function test_registryOwnerCannotUpgradeAnyVault() public {
        _listV21();
        _warp(30 days);
        assertEq(_impl(), address(genesis)); // listing a release changes nothing by itself
        vm.prank(registryOwner);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        vault.upgradeToAndCall(address(v21), "");
        vm.prank(registryOwner);
        vm.expectRevert(EPKVault.NotAdmin.selector);
        vault.scheduleUpgrade(address(v21), bytes32(0));
    }

    function test_implementationAndProxyCannotBeReinitialized() public {
        address[] memory g = new address[](2);
        g[0] = guardian;
        g[1] = guardian2;
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        genesis.initialize(attacker, g, DELAY, address(0), address(registry));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(attacker, g, DELAY, address(0), address(registry));
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        genesis.upgradeToAndCall(address(v21), "");
    }

    /// Review round 3 I-a: the vault can never be its own signer, validator or co-signer.
    function test_vaultCannotBeItsOwnSignerValidatorOrCoSigner() public {
        address[] memory g = new address[](2);
        g[0] = guardian;
        g[1] = guardian2;
        vm.prank(admin);
        EPKVault fresh = EPKVault(payable(factory.createVault(g, DELAY, address(0), bytes32("self"))));
        bytes memory err = abi.encodeWithSelector(EPKVault.BadRole.selector, address(fresh));
        vm.startPrank(admin);
        vm.expectRevert(err);
        fresh.createPolicy(address(fresh), 0, 0, address(0));
        vm.expectRevert(err);
        fresh.createPolicy(vm.addr(signerPk), 0, 0, address(fresh));
        vm.expectRevert(err);
        fresh.setCoSigner(address(fresh));
        vm.stopPrank();
    }

    /// Review round 2 F4: no new vaults on a revoked implementation.
    function test_factoryRefusesRevokedImplementation() public {
        vm.prank(registryOwner);
        registry.revokeRelease(address(genesis));
        address[] memory g = new address[](2);
        g[0] = guardian;
        g[1] = guardian2;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVaultFactory.ImplementationNotApproved.selector, address(genesis)));
        factory.createVault(g, DELAY, address(0), bytes32("new"));
    }

    /// Review round 2 F7: payers limited to the 2300-gas stipend can pay the vault in a cold transaction.
    function test_vaultAcceptsStipendTransfers() public {
        StipendPayer payer = new StipendPayer();
        vm.deal(address(this), 1 ether);
        payer.pay{value: 1 ether}(payable(address(vault)));
        assertEq(address(vault).balance, 1 ether);
    }

    function testFuzz_directUpgradeAlwaysFails(address caller, address impl) public {
        vm.prank(caller);
        vm.expectRevert();
        vault.upgradeToAndCall(impl, "");
        assertEq(_impl(), address(genesis));
    }

    // ------------------------------------------------------------------ registry

    /// Review round 2 F3/F8/I2: versions come from the code itself and cannot jump arbitrarily.
    function test_registryRules() public {
        FarFutureVault far = new FarFutureVault();
        EPKVault same = new EPKVault();

        vm.prank(attacker);
        vm.expectRevert(EPKRegistry.NotOwner.selector);
        registry.proposeRelease(address(v21));

        vm.startPrank(registryOwner);
        vm.expectRevert(abi.encodeWithSelector(EPKRegistry.VersionNotHigher.selector, 20_300, 20_300));
        registry.proposeRelease(address(same));
        vm.expectRevert(abi.encodeWithSelector(EPKRegistry.VersionStepTooLarge.selector, 20_300, 90_000));
        registry.proposeRelease(address(far));
        vm.expectRevert(abi.encodeWithSelector(EPKRegistry.NoCode.selector, attacker));
        registry.proposeRelease(attacker);
        vm.expectRevert(abi.encodeWithSelector(EPKRegistry.NotAVault.selector, address(token)));
        registry.proposeRelease(address(token));
        vm.expectRevert(abi.encodeWithSelector(EPKRegistry.AlreadyListed.selector, address(genesis)));
        registry.proposeRelease(address(genesis));
        vm.expectRevert(abi.encodeWithSelector(EPKRegistry.UnknownRelease.selector, attacker));
        registry.revokeRelease(attacker);
        registry.proposeRelease(address(v21));
        registry.transferOwnership(attacker);
        vm.stopPrank();

        assertFalse(registry.isApproved(address(v21))); // still in its public delay
        assertTrue(registry.isApproved(address(genesis)));
        assertEq(registry.versionOf(address(v21)), 20_400);

        vm.prank(guardian);
        vm.expectRevert(EPKRegistry.NotPendingOwner.selector);
        registry.acceptOwnership();
        vm.prank(attacker);
        registry.acceptOwnership();
        assertEq(registry.owner(), attacker);
    }

    function test_registryRejectsDelegatedCode() public {
        address delegated = makeAddr("7702-account");
        vm.etch(delegated, abi.encodePacked(hex"ef0100", address(v21)));
        vm.prank(registryOwner);
        vm.expectRevert(abi.encodeWithSelector(EPKRegistry.DelegatedCode.selector, delegated));
        registry.proposeRelease(delegated);
    }
}

/// Stateful: a compromised admin keeps trying to install code (including after lowering the vault
/// delay and through generic scheduling); honest guardians do nothing. The implementation may only
/// ever be an approved release, and an upgrade never lands sooner than UPGRADE_DELAY_FLOOR.
contract UpgradeHandler is Test {
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    EPKVault public vault;
    address public admin;
    address[3] public impls;
    mapping(bytes32 => uint256) public scheduledAt;
    uint256 public upgrades;
    uint256 public minWaitObserved = type(uint256).max;

    constructor(EPKVault vault_, address admin_, address a, address b, address c) {
        vault = vault_;
        admin = admin_;
        impls = [a, b, c];
    }

    function _implNow() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(vault), IMPL_SLOT))));
    }

    function scheduleUpgrade(uint256 which, uint256 saltSeed) external {
        vm.prank(admin);
        try vault.scheduleUpgrade(impls[which % 3], bytes32(saltSeed % 4)) returns (bytes32 id) {
            scheduledAt[id] = vm.getBlockTimestamp();
        } catch {}
    }

    function executeUpgrade(uint256 which, uint256 saltSeed) external {
        bytes memory data = vault.upgradeOperationData(impls[which % 3]);
        bytes32 salt = bytes32(saltSeed % 4);
        bytes32 id = vault.hashOperation(data, salt);
        address before = _implNow();
        vm.prank(admin);
        try vault.executeScheduled(data, salt) {
            if (_implNow() != before) {
                upgrades++;
                uint256 waited = vm.getBlockTimestamp() - scheduledAt[id];
                if (waited < minWaitObserved) minWaitObserved = waited;
            }
        } catch {}
    }

    function lowerDelay() external {
        bytes memory op = abi.encodeCall(EPKVault.setDelay, (1 hours));
        vm.startPrank(admin);
        try vault.schedule(op, bytes32("delay")) {} catch {}
        try vault.executeScheduled(op, bytes32("delay")) {} catch {}
        vm.stopPrank();
    }

    function directUpgrade(uint256 which) external {
        vm.prank(admin);
        try vault.upgradeToAndCall(impls[which % 3], "") {} catch {}
    }

    function genericSchedule(uint256 which, uint256 saltSeed) external {
        vm.startPrank(admin);
        try vault.schedule(vault.upgradeOperationData(impls[which % 3]), bytes32(saltSeed % 4)) {} catch {}
        try vault.schedule(abi.encodeCall(EPKVault.migrate, ()), bytes32(saltSeed % 4)) {} catch {}
        vm.stopPrank();
    }

    function wait(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 0, 2 days));
    }
}

contract EPKVaultUpgradeInvariantTest is UpgradeBase {
    UpgradeHandler handler;

    function setUp() public {
        _deployAll();
        _listV21();
        handler = new UpgradeHandler(vault, admin, address(v21), address(evil), address(genesis));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_implementationIsAlwaysAnApprovedRelease() public view {
        address impl = _impl();
        assertTrue(impl == address(genesis) || impl == address(v21), "unapproved implementation installed");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 40
    function invariant_upgradeNeverFasterThanTheFloor() public view {
        if (handler.upgrades() > 0) assertGe(handler.minWaitObserved(), vault.UPGRADE_DELAY_FLOOR());
    }
}

/// The current release (2.3.0) installs on a vault created with 2.1.0, like the vaults on
/// BSC Testnet: same address, funds and settings; the vault keeps working.
contract Upgrade210To220Test is UpgradeBase {
    function test_vault210UpgradesTo220() public {
        EPKVault210 old = new EPKVault210();
        EPKVault current = new EPKVault();
        registry = new EPKRegistry(registryOwner, address(old));
        factory = new EPKVaultFactory(address(old), address(registry));
        token = new TestToken("TKN");
        address[] memory g = new address[](2);
        g[0] = guardian;
        g[1] = guardian2;
        vm.prank(admin);
        vault = EPKVault(payable(factory.createVault(g, DELAY, recoveryKey, bytes32("u21"))));
        vm.startPrank(admin);
        vault.setAsset(address(token), 100e18, 1 days, type(uint128).max);
        vault.addDestination(friend);
        pid = vault.createPolicy(vm.addr(signerPk), 0, 0, address(0));
        vault.setAgent(pid, agent, true, 0);
        vault.setCall(pid, address(token), IERC20.transfer.selector, true);
        vault.finalizeSetup();
        vm.stopPrank();
        token.mint(address(vault), 1_000e18);
        assertEq(vault.vaultVersion(), 20_100);

        _list(address(current));
        _upgradeTo(address(current));

        assertEq(_impl(), address(current));
        assertEq(vault.vaultVersion(), 20_300);
        assertEq(vault.recovery(), recoveryKey);
        assertTrue(vault.isDestination(friend));
        assertEq(token.balanceOf(address(vault)), 1_000e18);
        _transferOnce(10e18);
        assertEq(token.balanceOf(friend), 10e18);
    }
}
