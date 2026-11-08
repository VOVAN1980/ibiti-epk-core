// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import {EPKVault} from "../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../contracts/v2/EPKVaultFactory.sol";
import {EPKRegistry} from "../../contracts/v2/EPKRegistry.sol";
import {TestToken} from "./V2Mocks.sol";

/// A batch target that, while the vault is executing it, tries to call back into the vault with a
/// list of prepared payloads and records which ones succeeded.
contract ReentrancyProbe {
    EPKVault public vault;
    bytes[] internal payloads;
    bool[] public results;

    function setVault(EPKVault v) external {
        vault = v;
    }

    function addPayload(bytes calldata p) external {
        payloads.push(p);
    }

    function payloadCount() external view returns (uint256) {
        return payloads.length;
    }

    function poke() external {
        delete results;
        for (uint256 i = 0; i < payloads.length; i++) {
            (bool ok,) = address(vault).call(payloads[i]);
            results.push(ok);
        }
    }

    function successes() external view returns (uint256 n) {
        for (uint256 i = 0; i < results.length; i++) {
            if (results[i]) n++;
        }
    }

    /// Lets the test prove that the prepared inner batch was valid on its own.
    function runDirect(uint256 index) external returns (bool ok) {
        (ok,) = address(vault).call(payloads[index]);
    }

    receive() external payable {}
}

/// Evidence for the two "high" Slither detectors on EPKVault (see docs/SLITHER_TRIAGE.md):
/// reentrancy-eth on execute() and arbitrary-send-eth on _runCalls().
contract EPKVaultReentrancyTest is Test {
    uint256 constant DELAY = 1 days;
    uint128 constant CAP = 100e18;

    EPKVaultFactory factory;
    EPKVault impl;
    TestToken token;

    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address guardian2 = makeAddr("guardian2");
    address agent = makeAddr("agent");
    address friend = makeAddr("friend");
    address attacker = makeAddr("attacker");
    uint256 signerPk = 0x51;
    uint256 pid;

    function setUp() public {
        impl = new EPKVault();
        EPKRegistry registry = new EPKRegistry(makeAddr("registryOwner"), address(impl));
        factory = new EPKVaultFactory(address(impl), address(registry));
        token = new TestToken("TKN");
    }

    // ------------------------------------------------------------------ helpers

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _vault(bytes32 salt, address extraGuardian, address extraAgent, address extraTarget)
        internal
        returns (EPKVault v)
    {
        address[] memory g = new address[](extraGuardian == address(0) ? 2 : 3);
        g[0] = guardian;
        g[1] = guardian2;
        if (extraGuardian != address(0)) g[2] = extraGuardian;
        vm.prank(admin);
        v = EPKVault(payable(factory.createVault(g, DELAY, address(0), salt)));

        vm.startPrank(admin);
        v.setAsset(address(token), CAP, 1 days, type(uint128).max);
        v.setAsset(v.NATIVE(), 1 ether, 1 days, type(uint128).max);
        v.addDestination(friend);
        pid = v.createPolicy(vm.addr(signerPk), 0, 1 ether, address(0));
        v.setAgent(pid, agent, true, 0);
        if (extraAgent != address(0)) v.setAgent(pid, extraAgent, true, 0);
        v.setCall(pid, address(token), IERC20.transfer.selector, true);
        v.setCall(pid, friend, bytes4(0), true);
        if (extraTarget != address(0)) {
            v.setCall(pid, extraTarget, ReentrancyProbe.poke.selector, true);
            v.setCall(pid, extraTarget, bytes4(0), true);
        }
        v.finalizeSetup();
        vm.stopPrank();

        token.mint(address(v), 1_000e18);
        vm.deal(address(v), 10 ether);
    }

    function _sign(EPKVault v, address agent_, EPKVault.Call[] memory calls, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 d = v.getExecuteDigest(pid, agent_, calls, nonce, deadline);
        (uint8 v_, bytes32 r, bytes32 s) = vm.sign(signerPk, d);
        return abi.encodePacked(r, s, v_);
    }

    function _transfer(address to, uint256 amount) internal view returns (EPKVault.Call memory) {
        return EPKVault.Call(address(token), 0, abi.encodeCall(IERC20.transfer, (to, amount)));
    }

    /// Outer batch: transfer 10 -> probe.poke() (re-entry attempts) -> transfer 5.
    function _outerWithPoke(EPKVault v, ReentrancyProbe probe) internal {
        EPKVault.Call[] memory calls = new EPKVault.Call[](3);
        calls[0] = _transfer(friend, 10e18);
        calls[1] = EPKVault.Call(address(probe), 0, abi.encodeCall(ReentrancyProbe.poke, ()));
        calls[2] = _transfer(friend, 5e18);
        uint256 deadline = _now() + 1 hours;
        bytes memory sig = _sign(v, agent, calls, v.nonces(pid), deadline);
        vm.prank(agent);
        v.execute(pid, calls, deadline, sig, "");
    }

    // ------------------------------------------------------------------ reentrancy-eth on execute()

    /// An unprivileged batch target tries every state-changing entry point of the vault while the
    /// batch is running — including a fully valid, pre-signed batch of its own. Nothing succeeds,
    /// and the outer batch's outflow is charged exactly once.
    function test_reentrancy_unprivilegedTargetCannotReenterAnything() public {
        ReentrancyProbe probe = new ReentrancyProbe();
        EPKVault v = _vault(bytes32("r1"), address(0), address(probe), address(probe));
        probe.setVault(v);

        // a ready timelock operation the probe will try to execute
        bytes memory addAttacker = abi.encodeCall(EPKVault.addDestination, (attacker));
        vm.prank(admin);
        bytes32 opId = v.schedule(addAttacker, bytes32(0));
        vm.warp(_now() + DELAY);

        // a VALID inner batch for the probe as agent, signed for the nonce right after the outer one
        EPKVault.Call[] memory inner = new EPKVault.Call[](1);
        inner[0] = _transfer(friend, 1e18);
        uint256 innerDeadline = _now() + 2 hours;
        bytes memory innerSig = _sign(v, address(probe), inner, v.nonces(pid) + 1, innerDeadline);

        probe.addPayload(abi.encodeCall(EPKVault.execute, (pid, inner, innerDeadline, innerSig, "")));
        probe.addPayload(abi.encodeCall(EPKVault.executeScheduled, (addAttacker, bytes32(0))));
        probe.addPayload(abi.encodeCall(EPKVault.schedule, (addAttacker, bytes32("p"))));
        probe.addPayload(abi.encodeCall(EPKVault.cancel, (opId)));
        probe.addPayload(abi.encodeCall(EPKVault.pause, ()));
        probe.addPayload(abi.encodeCall(EPKVault.panic, ()));
        probe.addPayload(abi.encodeCall(EPKVault.revokeAll, ()));
        probe.addPayload(abi.encodeCall(EPKVault.lowerAssetLimit, (address(token), 0, 0)));
        probe.addPayload(
            abi.encodeCall(EPKVault.setAsset, (address(token), type(uint128).max, 1, type(uint128).max))
        );
        probe.addPayload(abi.encodeCall(EPKVault.untrackAsset, (address(token))));
        probe.addPayload(addAttacker);
        probe.addPayload(abi.encodeCall(EPKVault.setCall, (pid, attacker, bytes4(0), true)));
        probe.addPayload(abi.encodeCall(EPKVault.setAdmin, (address(probe))));
        probe.addPayload(abi.encodeCall(EPKVault.scheduleUpgrade, (address(impl), bytes32(0))));
        probe.addPayload(abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(impl), "")));
        probe.addPayload(abi.encodeCall(EPKVault.migrate, ()));
        probe.addPayload(abi.encodeCall(EPKVault.recoverAdmin, (address(probe), bytes32(0))));

        uint256 availBefore = v.availableToSpend(address(token));
        _outerWithPoke(v, probe);

        assertEq(probe.successes(), 0, "a re-entrant call succeeded");
        assertEq(token.balanceOf(friend), 15e18, "outer batch ran");
        assertEq(v.availableToSpend(address(token)), availBefore - 15e18, "outflow charged exactly once");
        assertFalse(v.isDestination(attacker));
        assertFalse(v.paused());

        // the inner batch was genuinely valid: outside the outer execution it goes through
        assertTrue(probe.runDirect(0), "inner batch should be valid on its own");
        assertEq(token.balanceOf(friend), 16e18);
    }

    /// Even a batch target that IS a guardian can, mid-batch, only tighten rules; it cannot loosen
    /// anything or re-enter execution, and the outer outflow is still charged after its tightening.
    function test_reentrancy_guardianTargetCanOnlyTighten() public {
        ReentrancyProbe probe = new ReentrancyProbe();
        EPKVault v = _vault(bytes32("r2"), address(probe), address(0), address(probe));
        probe.setVault(v);

        probe.addPayload(abi.encodeCall(EPKVault.lowerAssetLimit, (address(token), 50e18, type(uint128).max)));
        probe.addPayload(abi.encodeCall(EPKVault.pause, ()));
        probe.addPayload(abi.encodeCall(EPKVault.unpause, ()));
        probe.addPayload(abi.encodeCall(EPKVault.addDestination, (attacker)));
        probe.addPayload(
            abi.encodeCall(EPKVault.setAsset, (address(token), type(uint128).max, 1, type(uint128).max))
        );
        probe.addPayload(abi.encodeCall(EPKVault.scheduleUpgrade, (address(impl), bytes32(0))));

        _outerWithPoke(v, probe);

        assertTrue(probe.results(0), "tightening allowed");
        assertTrue(probe.results(1), "pause allowed");
        assertFalse(probe.results(2), "unpause refused");
        assertFalse(probe.results(3), "new destination refused");
        assertFalse(probe.results(4), "raising the limit refused");
        assertFalse(probe.results(5), "upgrade refused");

        // limit lowered to 50 mid-batch, then the batch's 15 was charged against it
        assertEq(v.availableToSpend(address(token)), 35e18);
        assertTrue(v.paused());
        assertFalse(v.isDestination(attacker));
    }

    // ------------------------------------------------------------------ arbitrary-send-eth on _runCalls()

    /// Native value can only ever reach an allowlisted destination, even when the call itself is
    /// allowed for the policy and the batch is correctly signed.
    function testFuzz_nativeValueOnlyToAllowlistedDestinations(address target, uint96 rawValue) public {
        vm.assume(target != address(0) && target != friend && target.code.length == 0 && uint160(target) > 0xff);
        uint256 value = bound(uint256(rawValue), 1, 1 ether);
        EPKVault v = _vault(bytes32("fz"), address(0), address(0), target);
        vm.assume(target != address(v));

        EPKVault.Call[] memory calls = new EPKVault.Call[](1);
        calls[0] = EPKVault.Call(target, value, "");
        uint256 deadline = _now() + 1 hours;
        bytes memory sig = _sign(v, agent, calls, v.nonces(pid), deadline);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.DestinationNotAllowed.selector, target));
        v.execute(pid, calls, deadline, sig, "");
        assertEq(target.balance, 0);
    }

    function test_nativeToDestinationWorksAndIsLimited() public {
        EPKVault v = _vault(bytes32("nd"), address(0), address(0), address(0));
        EPKVault.Call[] memory calls = new EPKVault.Call[](1);
        calls[0] = EPKVault.Call(friend, 0.7 ether, "");
        uint256 deadline = _now() + 1 hours;
        bytes memory sig = _sign(v, agent, calls, v.nonces(pid), deadline);
        vm.prank(agent);
        v.execute(pid, calls, deadline, sig, "");
        assertEq(friend.balance, 0.7 ether);

        sig = _sign(v, agent, calls, v.nonces(pid), deadline);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.LimitExceeded.selector, address(0), 0.7 ether, 0.3 ether));
        v.execute(pid, calls, deadline, sig, "");
    }

    /// Without the policy signer's signature, or from a non-agent, nothing is sent anywhere.
    function test_nativeSendNeedsSignerAndAgent() public {
        EPKVault v = _vault(bytes32("ns"), address(0), address(0), address(0));
        EPKVault.Call[] memory calls = new EPKVault.Call[](1);
        calls[0] = EPKVault.Call(friend, 0.1 ether, "");
        uint256 deadline = _now() + 1 hours;

        bytes32 d = v.getExecuteDigest(pid, agent, calls, v.nonces(pid), deadline);
        (uint8 v_, bytes32 r, bytes32 s) = vm.sign(0xBAD, d); // not the policy signer
        vm.prank(agent);
        vm.expectRevert(EPKVault.BadSignature.selector);
        v.execute(pid, calls, deadline, abi.encodePacked(r, s, v_), "");

        bytes memory sig = _sign(v, agent, calls, v.nonces(pid), deadline);
        vm.prank(attacker);
        vm.expectRevert(EPKVault.AgentNotAllowed.selector);
        v.execute(pid, calls, deadline, sig, "");
        assertEq(friend.balance, 0);
    }
}
