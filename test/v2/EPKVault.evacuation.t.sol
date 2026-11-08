// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EPKVault, EPKVaultEmergency, IEPKVaultEmergency} from "../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../contracts/v2/EPKVaultFactory.sol";
import {EPKRegistry} from "../../contracts/v2/EPKRegistry.sol";
import {TestToken, FalseToken} from "./V2Mocks.sol";

/// A cold wallet contract that tries to re-enter the vault while it receives native coin.
contract ReenteringColdWallet {
    EPKVault public vault;
    bytes4 public reentryError;

    function setVault(EPKVault v) external {
        vault = v;
    }

    receive() external payable {
        try IEPKVaultEmergency(address(vault)).evacuate(new address[](0)) {
            reentryError = bytes4(0xffffffff); // must never happen
        } catch (bytes memory err) {
            reentryError = bytes4(err);
        }
    }
}

/// Emergency evacuation to the owner's cold wallet (vault 2.3.0) — docs/EVACUATION_v2.md, attacks E1–E12.
contract EPKVaultEvacuationTest is Test {
    EPKVaultFactory factory;
    EPKVault vault;
    TestToken token;
    TestToken untracked;
    FalseToken falseToken;

    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address guardian2 = makeAddr("guardian2");
    address recoveryKey = makeAddr("recovery");
    address manager = makeAddr("sessionManager");
    address coSigner = makeAddr("coSigner");
    address agent = makeAddr("agent");
    address cold = makeAddr("coldWallet");
    address watchtower = makeAddr("watchtower");
    address attacker = makeAddr("attacker");

    uint256 constant DELAY = 1 days;

    function setUp() public {
        EPKVault impl = new EPKVault();
        EPKRegistry registry = new EPKRegistry(makeAddr("registryOwner"), address(impl));
        factory = new EPKVaultFactory(address(impl), address(registry));
        token = new TestToken("TKN");
        untracked = new TestToken("UNT");
        falseToken = new FalseToken();
        vault = _newVault(DELAY, bytes32("main"));
        vm.startPrank(admin);
        vault.setAsset(address(token), 100e18, 1 days, type(uint128).max); // daily limit far below the balance
        vault.setAsset(vault.NATIVE(), 1 ether, 1 days, type(uint128).max);
        vault.setSessionManager(manager);
        vault.setCoSigner(coSigner);
        uint256 pid = vault.createPolicy(makeAddr("signer"), 0, 1 ether, address(0));
        vault.setAgent(pid, agent, true, 0);
        IEPKVaultEmergency(address(vault)).setColdWallet(cold); // during setup: direct
        vault.finalizeSetup();
        vm.stopPrank();
        token.mint(address(vault), 1_000e18);
        untracked.mint(address(vault), 500e18);
        vm.deal(address(vault), 10 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _newVault(uint256 delay, bytes32 salt) internal returns (EPKVault v) {
        address[] memory g = new address[](2);
        g[0] = guardian;
        g[1] = guardian2;
        vm.prank(admin);
        v = EPKVault(payable(factory.createVault(g, delay, recoveryKey, salt)));
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _all() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _timelocked(EPKVault v, bytes memory data, bytes32 salt, uint256 wait) internal {
        vm.prank(admin);
        v.schedule(data, salt);
        vm.warp(_now() + wait);
        vm.prank(admin);
        v.executeScheduled(data, salt);
    }

    // ------------------------------------------------------------------ what it does

    /// The admin evacuates: every tracked asset goes to the cold wallet — whole balances, far above the
    /// daily limits — and the vault is paused and revoked like after `panic`. Untracked tokens stay.
    function test_adminEvacuatesEverythingToTheColdWalletLikePanic() public {
        uint64 epochBefore = vault.epoch();
        vm.expectEmit(true, true, true, true, address(vault));
        emit EPKVault.Evacuated(address(token), 1_000e18, cold, admin);
        vm.prank(admin);
        IEPKVaultEmergency(address(vault)).evacuate(_all());
        assertEq(token.balanceOf(cold), 1_000e18);
        assertEq(cold.balance, 10 ether);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(address(vault).balance, 0);
        assertEq(untracked.balanceOf(address(vault)), 500e18); // never touched
        assertTrue(vault.paused());
        assertEq(vault.epoch(), epochBefore + 1);
    }

    function test_recoveryKeyEvacuates() public {
        vm.prank(recoveryKey);
        IEPKVaultEmergency(address(vault)).evacuate(_all());
        assertEq(token.balanceOf(cold), 1_000e18);
    }

    /// The optional evacuator (e.g. a Watchtower) is off by default; once set through the timelock it can
    /// evacuate — to the cold wallet only.
    function test_evacuatorOnlyOnceSetThroughTheTimelock() public {
        vm.prank(watchtower);
        vm.expectRevert(EPKVault.NotEvacuator.selector);
        IEPKVaultEmergency(address(vault)).evacuate(_all());

        _timelocked(vault, abi.encodeCall(IEPKVaultEmergency.setEvacuator, (watchtower)), bytes32("e"), DELAY);
        assertEq(vault.evacuator(), watchtower);
        vm.prank(watchtower);
        IEPKVaultEmergency(address(vault)).evacuate(_all());
        assertEq(token.balanceOf(cold), 1_000e18);
    }

    /// Repeating it is harmless: nothing is left to move, the vault stays paused.
    function test_evacuateTwiceIsHarmless() public {
        vm.prank(admin);
        IEPKVaultEmergency(address(vault)).evacuate(_all());
        vm.prank(admin);
        IEPKVaultEmergency(address(vault)).evacuate(_all());
        assertEq(token.balanceOf(cold), 1_000e18);
        assertTrue(vault.paused());
    }

    // ------------------------------------------------------------------ attacks

    /// E1 + guardian rule: guardians, agents, the session manager, the co-signer, the cold wallet itself and
    /// strangers can never evacuate.
    function test_E1_noOtherRoleCanEvacuate() public {
        address[7] memory nope = [guardian, guardian2, agent, manager, coSigner, cold, attacker];
        for (uint256 i = 0; i < nope.length; i++) {
            vm.prank(nope[i]);
            vm.expectRevert(EPKVault.NotEvacuator.selector);
            IEPKVaultEmergency(address(vault)).evacuate(_all());
        }
        assertEq(token.balanceOf(address(vault)), 1_000e18);
    }

    function testFuzz_E1_onlyTheThreeRolesCanEvacuate(address caller) public {
        vm.assume(caller != admin && caller != recoveryKey && caller != address(0));
        vm.prank(caller);
        vm.expectRevert(EPKVault.NotEvacuator.selector);
        IEPKVaultEmergency(address(vault)).evacuate(_all());
    }

    /// E1: a policy or session batch can never be configured to call the vault itself.
    function test_E1_batchesCanNeverTargetTheVault() public {
        EPKVault fresh = _newVault(DELAY, bytes32("fresh"));
        vm.startPrank(admin);
        uint256 pid = fresh.createPolicy(makeAddr("s2"), 0, 0, address(0));
        vm.expectRevert(EPKVault.BadTarget.selector);
        fresh.setCall(pid, address(fresh), IEPKVaultEmergency.evacuate.selector, true);
        vm.expectRevert(EPKVault.BadTarget.selector);
        fresh.setCall(pid, address(fresh), IEPKVaultEmergency.setColdWallet.selector, true);
        vm.stopPrank();
    }

    /// E2: a stolen admin key schedules "cold wallet = mine". It waits 3 x delay (here 3 days), any guardian
    /// cancels it, and evacuation meanwhile still goes only to the owner's cold wallet.
    function test_E2_stolenAdminKeyCannotRedirectTheColdWallet() public {
        bytes memory change = abi.encodeCall(IEPKVaultEmergency.setColdWallet, (attacker));
        vm.prank(admin);
        bytes32 id = vault.schedule(change, bytes32("x"));

        vm.warp(_now() + 3 days - 1);
        vm.prank(admin);
        vm.expectRevert(EPKVault.OperationNotReady.selector);
        vault.executeScheduled(change, bytes32("x"));

        vm.prank(guardian);
        vault.cancel(id);
        vm.warp(_now() + 1 days);
        vm.prank(admin);
        vm.expectRevert(EPKVault.UnknownOperation.selector);
        vault.executeScheduled(change, bytes32("x"));

        vm.prank(admin);
        IEPKVaultEmergency(address(vault)).evacuate(_all());
        assertEq(token.balanceOf(cold), 1_000e18);
        assertEq(token.balanceOf(attacker), 0);
    }

    /// E2 / decision 2: on production networks a cold-wallet change waits at least 2 days, even with the
    /// shortest (1-hour) vault delay.
    function test_E2_coldWalletChangeWaitsAtLeastTwoDays() public {
        EPKVault v = _newVault(1 hours, bytes32("short"));
        vm.prank(admin);
        v.finalizeSetup();
        address newCold = makeAddr("newCold");
        bytes memory change = abi.encodeCall(IEPKVaultEmergency.setColdWallet, (newCold));
        vm.prank(admin);
        v.schedule(change, bytes32("c"));
        vm.warp(_now() + 2 days - 1);
        vm.prank(admin);
        vm.expectRevert(EPKVault.OperationNotReady.selector);
        v.executeScheduled(change, bytes32("c"));
        vm.warp(_now() + 1);
        vm.prank(admin);
        v.executeScheduled(change, bytes32("c"));
        assertEq(v.coldWallet(), newCold);
    }

    /// On test networks the same change takes 3 x delay: 15 minutes with the 5-minute test-network delay.
    function test_testnet_coldWalletChangeInFifteenMinutes() public {
        vm.chainId(97);
        EPKVault impl = new EPKVault();
        EPKRegistry r = new EPKRegistry(makeAddr("registryOwner"), address(impl));
        factory = new EPKVaultFactory(address(impl), address(r));
        EPKVault v = _newVault(5 minutes, bytes32("testnet"));
        vm.prank(admin);
        v.finalizeSetup();
        bytes memory change = abi.encodeCall(IEPKVaultEmergency.setColdWallet, (makeAddr("c2")));
        vm.prank(admin);
        v.schedule(change, bytes32("t"));
        vm.warp(_now() + 15 minutes - 1);
        vm.prank(admin);
        vm.expectRevert(EPKVault.OperationNotReady.selector);
        v.executeScheduled(change, bytes32("t"));
        vm.warp(_now() + 1);
        vm.prank(admin);
        v.executeScheduled(change, bytes32("t"));
        assertEq(v.coldWallet(), makeAddr("c2"));
    }

    /// E10: a cold-wallet change is an ordinary operation — a panic kills it.
    function test_E10_panicKillsAPendingColdWalletChange() public {
        bytes memory change = abi.encodeCall(IEPKVaultEmergency.setColdWallet, (attacker));
        vm.prank(admin);
        vault.schedule(change, bytes32("p"));
        vm.prank(guardian);
        vault.panic();
        vm.warp(_now() + 4 days);
        vm.prank(admin);
        vm.expectRevert(EPKVault.StaleOperation.selector);
        vault.executeScheduled(change, bytes32("p"));
        assertEq(vault.coldWallet(), cold);
    }

    /// E2: after setup the admin cannot set the cold wallet or the evacuator directly.
    function test_E2_noDirectChangeAfterSetup() public {
        vm.startPrank(admin);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        IEPKVaultEmergency(address(vault)).setColdWallet(attacker);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        IEPKVaultEmergency(address(vault)).setEvacuator(attacker);
        vm.stopPrank();
    }

    /// E7: the recovery key cannot schedule a cold-wallet change; it can cancel one.
    function test_E7_recoveryKeyCannotRedirectButCanCancel() public {
        bytes memory change = abi.encodeCall(IEPKVaultEmergency.setColdWallet, (attacker));
        vm.prank(recoveryKey);
        vm.expectRevert(EPKVault.NotAdmin.selector);
        vault.schedule(change, bytes32("r"));
        vm.prank(admin);
        bytes32 id = vault.schedule(change, bytes32("r"));
        vm.prank(recoveryKey);
        vault.cancel(id);
    }

    /// Separate keys: the cold wallet and the evacuator never share a key with a role that runs the vault
    /// or with each other (so theft through evacuation always needs two keys).
    function test_separateKeysAreEnforced() public {
        EPKVault v = _newVault(DELAY, bytes32("keys"));
        vm.startPrank(admin);
        v.setSessionManager(manager);
        v.setCoSigner(coSigner);
        address[7] memory taken = [admin, guardian, guardian2, recoveryKey, manager, coSigner, address(v)];
        for (uint256 i = 0; i < taken.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(EPKVault.BadRole.selector, taken[i]));
            IEPKVaultEmergency(address(v)).setColdWallet(taken[i]);
            vm.expectRevert(abi.encodeWithSelector(EPKVault.BadRole.selector, taken[i]));
            IEPKVaultEmergency(address(v)).setEvacuator(taken[i]);
        }
        IEPKVaultEmergency(address(v)).setColdWallet(cold);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.BadRole.selector, cold));
        IEPKVaultEmergency(address(v)).setEvacuator(cold);
        IEPKVaultEmergency(address(v)).setEvacuator(watchtower);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.BadRole.selector, watchtower));
        IEPKVaultEmergency(address(v)).setColdWallet(watchtower);
        IEPKVaultEmergency(address(v)).setEvacuator(address(0)); // switching the evacuator off is always possible
        assertEq(v.evacuator(), address(0));
        vm.stopPrank();
    }

    /// E8: a cold wallet contract that re-enters while receiving native coin is refused; the evacuation of
    /// everything else completes.
    function test_E8_reentrantColdWalletIsRefused() public {
        ReenteringColdWallet rcw = new ReenteringColdWallet();
        EPKVault v = _newVault(DELAY, bytes32("reenter"));
        rcw.setVault(v);
        vm.startPrank(admin);
        v.setAsset(v.NATIVE(), 1 ether, 1 days, type(uint128).max);
        IEPKVaultEmergency(address(v)).setColdWallet(address(rcw));
        v.finalizeSetup();
        vm.stopPrank();
        vm.deal(address(v), 3 ether);
        vm.prank(admin);
        IEPKVaultEmergency(address(v)).evacuate(_all());
        assertEq(address(rcw).balance, 3 ether);
        assertEq(rcw.reentryError(), EPKVault.Reentrancy.selector);
    }

    /// E9: a token that refuses names itself and stops the call; an explicit list evacuates the rest.
    function test_E9_refusingTokenIsNamedAndCanBeLeftOut() public {
        EPKVault v = _newVault(DELAY, bytes32("false"));
        vm.startPrank(admin);
        v.setAsset(address(token), 100e18, 1 days, type(uint128).max);
        v.setAsset(address(falseToken), 100e18, 1 days, type(uint128).max);
        IEPKVaultEmergency(address(v)).setColdWallet(cold);
        v.finalizeSetup();
        vm.stopPrank();
        token.mint(address(v), 7e18);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.TokenCallFailed.selector, address(falseToken)));
        IEPKVaultEmergency(address(v)).evacuate(_all());

        address[] memory only = new address[](1);
        only[0] = address(token);
        vm.prank(admin);
        IEPKVaultEmergency(address(v)).evacuate(only);
        assertEq(token.balanceOf(cold), 7e18);
    }

    /// E9: untracked tokens are never called by an evacuation.
    function test_E9_untrackedTokenIsRefused() public {
        address[] memory list = new address[](1);
        list[0] = address(untracked);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.UntrackedAsset.selector, address(untracked)));
        IEPKVaultEmergency(address(vault)).evacuate(list);
    }

    /// E11: no cold wallet registered — evacuation is off.
    function test_E11_noColdWalletNoEvacuation() public {
        EPKVault v = _newVault(DELAY, bytes32("none"));
        vm.prank(admin);
        v.finalizeSetup();
        vm.prank(admin);
        vm.expectRevert(EPKVault.NoColdWallet.selector);
        IEPKVaultEmergency(address(v)).evacuate(_all());
    }

    /// Size guard (design §6): the vault keeps at least 100 bytes under the EIP-170 limit of 24,576 bytes.
    function test_vaultKeepsAtLeast100BytesUnderEIP170() public {
        assertLe(address(new EPKVault()).code.length, 24_476);
    }

    /// Called directly (not through a vault), the emergency module has no admin, cold wallet or assets.
    function test_moduleCalledDirectlyDoesNothing() public {
        EPKVaultEmergency m = new EPKVaultEmergency();
        vm.prank(admin);
        vm.expectRevert(EPKVault.NotEvacuator.selector);
        m.evacuate(_all());
        vm.prank(admin);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        m.setColdWallet(attacker);
    }

    /// Any other unknown call to the vault still reverts (the module has no other functions).
    function test_unknownCallsStillRevert() public {
        (bool ok,) = address(vault).call(abi.encodeWithSignature("drain(address)", attacker));
        assertFalse(ok);
        (ok,) = address(vault).call{value: 1}(abi.encodeWithSignature("evacuate(address[])", new address[](0)));
        assertFalse(ok); // not payable
    }

    /// Ordinary operation is untouched: without an evacuation nothing changes for policies, limits and
    /// the timelock (the full existing suite runs on the same vault code).
    function test_evacuationIsNotNeededForOrdinaryUse() public view {
        assertFalse(vault.paused());
        assertEq(vault.coldWallet(), cold);
        assertEq(vault.evacuator(), address(0));
    }
}
