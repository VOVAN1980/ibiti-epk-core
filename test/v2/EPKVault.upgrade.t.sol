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

/// A future release: new feature + appended storage + one-time migration (vault-only).
contract EPKVaultV21 is EPKVault {
    uint256 public newSetting; // appended after all v2.0.0 storage

    function vaultVersion() public pure override returns (uint64) {
        return 20_100; // 2.1.0
    }

    function migrate() external override reinitializer(2) {
        if (msg.sender != address(this)) revert NotTimelocked();
        newSetting = 42;
    }

    function hello() external pure returns (string memory) {
        return "2.1";
    }
}

/// What an attacker would like to install.
contract MaliciousVault is EPKVault {
    function vaultVersion() public pure override returns (uint64) {
        return 20_200;
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

    function _listV21() internal {
        vm.prank(registryOwner);
        registry.proposeRelease(address(v21));
        _warp(registry.APPROVAL_DELAY());
    }

    /// @dev Built locally (no external call), so vm.prank / expectRevert hit the intended call.
    function _op(address impl, bool withMigration) internal pure returns (bytes memory) {
        bytes memory init = withMigration ? abi.encodeCall(EPKVault.migrate, ()) : bytes("");
        return abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (impl, init));
    }

    function _upgradeV21(bool withMigration) internal {
        vm.prank(admin);
        vault.scheduleUpgrade(address(v21), withMigration, bytes32(0));
        _warp(2 * DELAY);
        vm.prank(admin);
        vault.executeScheduled(_op(address(v21), withMigration), bytes32(0));
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
        assertEq(vault.upgradeOperationData(address(v21), true), _op(address(v21), true));
        assertEq(vault.upgradeOperationData(address(v21), false), _op(address(v21), false));
    }

    function test_vaultIsProxyOnGenesis() public view {
        assertEq(_impl(), address(genesis));
        assertEq(vault.vaultVersion(), 20_000);
        assertEq(vault.registry(), address(registry));
        assertEq(registry.versionOf(address(genesis)), 20_000);
    }

    function test_upgradeKeepsAddressFundsAndSettings() public {
        _transferOnce(10e18);
        _listV21();
        _upgradeV21(true);

        // same address, new code, migrated state
        assertEq(_impl(), address(v21));
        assertEq(vault.vaultVersion(), 20_100);
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

    /// Review F2: a migration can never be run by an outsider.
    function test_migrationOnlyByTheVaultItself() public {
        vm.prank(attacker);
        vm.expectRevert(EPKVault.BadOperation.selector); // 2.0.0 has nothing to migrate
        vault.migrate();

        _listV21();
        _upgradeV21(false); // upgraded without running the migration
        vm.prank(attacker);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        vault.migrate();
        assertEq(EPKVaultV21(payable(address(vault))).newSetting(), 0);

        vm.prank(admin);
        vm.expectRevert(EPKVault.BadOperation.selector); // and not through the generic timelock either
        vault.schedule(abi.encodeCall(EPKVault.migrate, ()), bytes32(0));
    }

    function test_upgradeNeedsTwiceTheDelay() public {
        _listV21();
        vm.prank(admin);
        vault.scheduleUpgrade(address(v21), false, bytes32(0));
        _warp(DELAY);
        vm.prank(admin);
        vm.expectRevert(EPKVault.OperationNotReady.selector);
        vault.executeScheduled(_op(address(v21), false), bytes32(0));
        _warp(DELAY);
        vm.prank(admin);
        vault.executeScheduled(_op(address(v21), false), bytes32(0));
        assertEq(_impl(), address(v21));
    }

    /// Review F5: lowering the vault delay first does not make upgrades faster than the floor.
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
        vault.scheduleUpgrade(address(v21), false, bytes32(0));
        _warp(2 hours);
        vm.prank(admin);
        vm.expectRevert(EPKVault.OperationNotReady.selector);
        vault.executeScheduled(_op(address(v21), false), bytes32(0));
        _warp(vault.UPGRADE_DELAY_FLOOR() - 2 hours);
        vm.prank(admin);
        vault.executeScheduled(_op(address(v21), false), bytes32(0));
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
        vault.schedule(_op(address(v21), false), bytes32(0));

        vm.prank(admin);
        vm.expectRevert(EPKVault.UnknownOperation.selector);
        vault.executeScheduled(_op(address(v21), false), bytes32(0));
        assertEq(_impl(), address(genesis));
    }

    function test_compromisedAdminCannotInstallUnapprovedCode() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.ImplementationNotApproved.selector, address(evil)));
        vault.scheduleUpgrade(address(evil), false, bytes32(0));
        assertEq(_impl(), address(genesis));
    }

    function test_releaseUsableOnlyAfterRegistryDelay() public {
        vm.prank(registryOwner);
        registry.proposeRelease(address(v21));
        _warp(registry.APPROVAL_DELAY() - 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.ImplementationNotApproved.selector, address(v21)));
        vault.scheduleUpgrade(address(v21), false, bytes32(0));
        _warp(1);
        vm.prank(admin);
        vault.scheduleUpgrade(address(v21), false, bytes32(0));
    }

    function test_revokedReleaseCannotBeInstalled() public {
        _listV21();
        vm.prank(admin);
        vault.scheduleUpgrade(address(v21), false, bytes32(0));
        vm.prank(registryOwner);
        registry.revokeRelease(address(v21));
        _warp(2 * DELAY);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.ImplementationNotApproved.selector, address(v21)));
        vault.executeScheduled(_op(address(v21), false), bytes32(0));
        assertEq(_impl(), address(genesis));
    }

    function test_noDowngrade() public {
        _listV21();
        _upgradeV21(false);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.NotNewerVersion.selector, 20_100, 20_000));
        vault.scheduleUpgrade(address(genesis), false, bytes32(0));
    }

    function test_guardianVetoAndPanicStopUpgrades() public {
        _listV21();
        vm.prank(admin);
        bytes32 id = vault.scheduleUpgrade(address(v21), false, bytes32("a"));
        vm.prank(guardian);
        vault.cancel(id);

        vm.prank(admin);
        vault.scheduleUpgrade(address(v21), false, bytes32("b"));
        vm.prank(guardian2);
        vault.panic();

        _warp(2 * DELAY);
        vm.startPrank(admin);
        vm.expectRevert(EPKVault.UnknownOperation.selector);
        vault.executeScheduled(_op(address(v21), false), bytes32("a"));
        vm.expectRevert(EPKVault.StaleOperation.selector);
        vault.executeScheduled(_op(address(v21), false), bytes32("b"));
        vm.stopPrank();
        assertEq(_impl(), address(genesis));
    }

    /// Review I7: the recovery key can only execute its own recovery operations.
    function test_recoveryCannotExecuteAdminOperations() public {
        _listV21();
        vm.prank(admin);
        vault.scheduleUpgrade(address(v21), false, bytes32(0));
        _warp(2 * DELAY);
        vm.prank(recoveryKey);
        vm.expectRevert(EPKVault.NotAdminOrRecovery.selector);
        vault.executeScheduled(_op(address(v21), false), bytes32(0));
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
        vault.scheduleUpgrade(address(v21), false, bytes32(0));
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

    /// Review F4: no new vaults on a revoked implementation.
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

    /// Review F7: payers limited to the 2300-gas stipend can pay the vault in a cold transaction.
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

    /// Review F3/F8/I2: versions come from the code itself and cannot jump arbitrarily.
    function test_registryRules() public {
        FarFutureVault far = new FarFutureVault();
        EPKVault same = new EPKVault();

        vm.prank(attacker);
        vm.expectRevert(EPKRegistry.NotOwner.selector);
        registry.proposeRelease(address(v21));

        vm.startPrank(registryOwner);
        vm.expectRevert(abi.encodeWithSelector(EPKRegistry.VersionNotHigher.selector, 20_000, 20_000));
        registry.proposeRelease(address(same));
        vm.expectRevert(abi.encodeWithSelector(EPKRegistry.VersionStepTooLarge.selector, 20_000, 90_000));
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
        assertEq(registry.versionOf(address(v21)), 20_100);

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
/// delay and with migrations); honest guardians do nothing. The implementation may only ever be an
/// approved release, and an upgrade never lands sooner than UPGRADE_DELAY_FLOOR after scheduling.
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

    function scheduleUpgrade(uint256 which, bool withMigration, uint256 saltSeed) external {
        vm.prank(admin);
        try vault.scheduleUpgrade(impls[which % 3], withMigration, bytes32(saltSeed % 4)) returns (bytes32 id) {
            scheduledAt[id] = vm.getBlockTimestamp();
        } catch {}
    }

    function executeUpgrade(uint256 which, bool withMigration, uint256 saltSeed) external {
        bytes memory data = vault.upgradeOperationData(impls[which % 3], withMigration);
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

    function genericSchedule(uint256 which, bool withMigration, uint256 saltSeed) external {
        vm.startPrank(admin);
        try vault.schedule(vault.upgradeOperationData(impls[which % 3], withMigration), bytes32(saltSeed % 4)) {}
        catch {}
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
