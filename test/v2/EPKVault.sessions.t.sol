// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EPKVault} from "../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../contracts/v2/EPKVaultFactory.sol";
import {EPKRegistry} from "../../contracts/v2/EPKRegistry.sol";
import {TestToken} from "./V2Mocks.sol";

abstract contract SessionBase is Test {
    uint256 constant DELAY = 1 days;
    uint128 constant VAULT_CAP = 100e18; // per day, whole vault
    uint128 constant SESSION_BUDGET = 30e18; // per day, each session
    uint256 constant ENV = 7; // envelope id

    EPKVaultFactory factory;
    EPKVault vault;
    TestToken token;

    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address guardian2 = makeAddr("guardian2");
    address manager = makeAddr("sessionManager");
    address friend = makeAddr("friend");
    address attacker = makeAddr("attacker");

    function _deploy() internal {
        EPKVault impl = new EPKVault();
        EPKRegistry registry = new EPKRegistry(makeAddr("registryOwner"), address(impl));
        factory = new EPKVaultFactory(address(impl), address(registry));
        token = new TestToken("TKN");

        address[] memory g = new address[](2);
        g[0] = guardian;
        g[1] = guardian2;
        vm.prank(admin);
        vault = EPKVault(payable(factory.createVault(g, DELAY, address(0), bytes32("s"))));

        vm.startPrank(admin);
        vault.setAsset(address(token), VAULT_CAP, 1 days, type(uint128).max);
        vault.setAsset(address(0), 1 ether, 1 days, type(uint128).max);
        vault.addDestination(friend);
        vault.setSessionManager(manager);
        vault.setEnvelope(ENV, true, 1 days, 0.1 ether);
        vault.setEnvelopeCall(ENV, address(token), IERC20.transfer.selector, true);
        vault.setEnvelopeCall(ENV, friend, bytes4(0), true);
        vault.setEnvelopeBudgetCap(ENV, address(token), SESSION_BUDGET);
        vault.finalizeSetup();
        vm.stopPrank();

        token.mint(address(vault), 1_000e18);
        vm.deal(address(vault), 10 ether);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _warp(uint256 secs) internal {
        vm.warp(_now() + secs);
    }

    /// The agent's own key signs AND submits — fully autonomous.
    function _open(uint256 agentPk, uint48 ttl) internal returns (uint256 sid) {
        address agent = vm.addr(agentPk);
        vm.prank(manager);
        sid = vault.openSession(ENV, agent, agent, uint48(_now() + ttl));
    }

    function _one(address target, uint256 value, bytes memory data) internal pure returns (EPKVault.Call[] memory c) {
        c = new EPKVault.Call[](1);
        c[0] = EPKVault.Call(target, value, data);
    }

    function _signed(uint256 sid, uint256 agentPk, EPKVault.Call[] memory calls)
        internal
        view
        returns (bytes memory sig, uint256 deadline)
    {
        deadline = _now() + 1 hours;
        bytes32 d = vault.getExecuteDigest(sid, vm.addr(agentPk), calls, vault.nonces(sid), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPk, d);
        sig = abi.encodePacked(r, s, v);
    }

    function _act(uint256 sid, uint256 agentPk, EPKVault.Call[] memory calls) internal {
        (bytes memory sig, uint256 deadline) = _signed(sid, agentPk, calls);
        vm.prank(vm.addr(agentPk));
        vault.execute(sid, calls, deadline, sig, "");
    }

    function _actFails(uint256 sid, uint256 agentPk, EPKVault.Call[] memory calls, bytes memory err) internal {
        (bytes memory sig, uint256 deadline) = _signed(sid, agentPk, calls);
        vm.expectRevert(err);
        vm.prank(vm.addr(agentPk));
        vault.execute(sid, calls, deadline, sig, "");
    }

    function _pay(uint256 amount) internal view returns (EPKVault.Call[] memory) {
        return _one(address(token), 0, abi.encodeCall(IERC20.transfer, (friend, amount)));
    }
}

contract EPKVaultSessionsTest is SessionBase {
    uint256 constant AGENT_A = 0xA1;
    uint256 constant AGENT_B = 0xB2;

    function setUp() public {
        _deploy();
    }

    function test_sessionOpensInstantlyAndAgentActsAlone() public {
        uint256 sid = _open(AGENT_A, 1 hours);
        _act(sid, AGENT_A, _pay(10e18));
        assertEq(token.balanceOf(friend), 10e18);
        assertEq(vault.budgetAvailable(sid, address(token)), SESSION_BUDGET - 10e18);
        assertEq(vault.availableToSpend(address(token)), VAULT_CAP - 10e18);
    }

    function test_eachSessionHasItsOwnBudget() public {
        uint256 a = _open(AGENT_A, 1 hours);
        uint256 b = _open(AGENT_B, 1 hours);
        _act(a, AGENT_A, _pay(30e18));
        _actFails(
            a, AGENT_A, _pay(1e18), abi.encodeWithSelector(EPKVault.BudgetExceeded.selector, address(token), 1e18, 0)
        );
        _act(b, AGENT_B, _pay(30e18)); // B is not affected by A
        assertEq(token.balanceOf(friend), 60e18);

        _warp(12 hours); // half a window refills half the session budget
        assertEq(vault.budgetAvailable(a, address(token)), 15e18);
    }

    function test_sessionsTogetherStayInsideTheVaultLimit() public {
        uint256[4] memory pks = [uint256(0xC1), 0xC2, 0xC3, 0xC4];
        for (uint256 i = 0; i < 3; i++) {
            _act(_open(pks[i], 1 hours), pks[i], _pay(30e18));
        }
        uint256 last = _open(pks[3], 1 hours);
        _actFails(
            last,
            pks[3],
            _pay(30e18),
            abi.encodeWithSelector(EPKVault.LimitExceeded.selector, address(token), 30e18, 10e18)
        );
    }

    function test_openSessionMustFitTheEnvelope() public {
        address agent = vm.addr(AGENT_A);
        vm.startPrank(manager);
        vm.expectRevert(EPKVault.OutsideEnvelope.selector);
        vault.openSession(ENV, agent, agent, uint48(_now() + 2 days)); // longer than maxTtl
        vm.expectRevert(EPKVault.OutsideEnvelope.selector);
        vault.openSession(ENV, agent, agent, uint48(_now())); // not in the future
        vm.expectRevert(EPKVault.OutsideEnvelope.selector);
        vault.openSession(ENV + 1, agent, agent, uint48(_now() + 1 hours)); // unknown / inactive envelope
        vm.expectRevert(abi.encodeWithSelector(EPKVault.BadRole.selector, address(vault)));
        vault.openSession(ENV, address(vault), agent, uint48(_now() + 1 hours));
        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert(EPKVault.NotSessionManager.selector);
        vault.openSession(ENV, agent, agent, uint48(_now() + 1 hours));
    }

    function test_sessionCanOnlyDoWhatTheEnvelopeAllows() public {
        uint256 sid = _open(AGENT_A, 1 hours);
        // a call the envelope does not allow
        _actFails(
            sid,
            AGENT_A,
            _one(address(token), 0, abi.encodeCall(IERC20.approve, (friend, 1))),
            abi.encodeWithSelector(EPKVault.CallNotAllowed.selector)
        );
        // native coin: the call is allowed but the envelope gives sessions no native budget
        _actFails(
            sid,
            AGENT_A,
            _one(friend, 0.05 ether, ""),
            abi.encodeWithSelector(EPKVault.BudgetExceeded.selector, address(0), 0.05 ether, 0)
        );
        // more value per call than the envelope allows
        _actFails(
            sid, AGENT_A, _one(friend, 0.2 ether, ""), abi.encodeWithSelector(EPKVault.ValueTooHigh.selector)
        );
        // still only allowlisted destinations
        _actFails(
            sid,
            AGENT_A,
            _one(address(token), 0, abi.encodeCall(IERC20.transfer, (attacker, 1e18))),
            abi.encodeWithSelector(EPKVault.DestinationNotAllowed.selector, attacker)
        );
    }

    function test_sessionExpires() public {
        uint256 sid = _open(AGENT_A, 1 hours);
        _warp(1 hours + 1);
        _actFails(sid, AGENT_A, _pay(1e18), abi.encodeWithSelector(EPKVault.Expired.selector));
    }

    function test_managerOrGuardianClosesASession() public {
        uint256 a = _open(AGENT_A, 1 hours);
        uint256 b = _open(AGENT_B, 1 hours);
        vm.prank(manager);
        vault.revokePolicy(a);
        vm.prank(guardian);
        vault.revokePolicy(b);
        _actFails(a, AGENT_A, _pay(1e18), abi.encodeWithSelector(EPKVault.PolicyInactive.selector));
        _actFails(b, AGENT_B, _pay(1e18), abi.encodeWithSelector(EPKVault.PolicyInactive.selector));
    }

    function test_narrowingTheEnvelopeAppliesToOpenSessionsInstantly() public {
        uint256 sid = _open(AGENT_A, 1 hours);

        vm.prank(guardian);
        vault.setEnvelopeBudgetCap(ENV, address(token), 5e18);
        assertEq(vault.budgetAvailable(sid, address(token)), 5e18);
        _actFails(
            sid, AGENT_A, _pay(6e18), abi.encodeWithSelector(EPKVault.BudgetExceeded.selector, address(token), 6e18, 5e18)
        );

        vm.prank(guardian);
        vault.setEnvelopeCall(ENV, address(token), IERC20.transfer.selector, false);
        _actFails(sid, AGENT_A, _pay(1e18), abi.encodeWithSelector(EPKVault.CallNotAllowed.selector));
    }

    function test_switchingTheEnvelopeOffStopsAllItsSessions() public {
        uint256 a = _open(AGENT_A, 1 hours);
        uint256 b = _open(AGENT_B, 1 hours);
        vm.prank(guardian);
        vault.setEnvelope(ENV, false, 1 days, 0.1 ether);
        _actFails(a, AGENT_A, _pay(1e18), abi.encodeWithSelector(EPKVault.PolicyInactive.selector));
        _actFails(b, AGENT_B, _pay(1e18), abi.encodeWithSelector(EPKVault.PolicyInactive.selector));
        vm.prank(manager);
        vm.expectRevert(EPKVault.OutsideEnvelope.selector);
        vault.openSession(ENV, vm.addr(AGENT_A), vm.addr(AGENT_A), uint48(_now() + 1 hours));
    }

    function test_wideningTheEnvelopeNeedsTheTimelock() public {
        vm.startPrank(admin);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        vault.setEnvelopeCall(ENV, address(token), IERC20.approve.selector, true);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        vault.setEnvelopeBudgetCap(ENV, address(token), SESSION_BUDGET + 1);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        vault.setEnvelope(ENV, true, 2 days, 0.1 ether);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        vault.setEnvelope(ENV + 1, true, 1 hours, 0);

        bytes memory op = abi.encodeCall(EPKVault.setEnvelopeBudgetCap, (ENV, address(token), 50e18));
        vault.schedule(op, bytes32(0));
        vm.stopPrank();
        _warp(DELAY);
        vm.prank(admin);
        vault.executeScheduled(op, bytes32(0));
        assertEq(vault.envelopeBudgetCap(ENV, address(token)), 50e18);
    }

    function test_guardiansCannotWiden() public {
        vm.startPrank(guardian);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        vault.setEnvelopeBudgetCap(ENV, address(token), SESSION_BUDGET + 1);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        vault.setSessionManager(attacker);
        vm.stopPrank();
        vm.prank(attacker);
        vm.expectRevert(EPKVault.NotAdminOrGuardian.selector);
        vault.setEnvelopeBudgetCap(ENV, address(token), 0);
    }

    function test_sessionManagerChangeIsTimelocked_removalIsInstant() public {
        vm.prank(admin);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        vault.setSessionManager(attacker);

        vm.prank(guardian);
        vault.setSessionManager(address(0));
        vm.prank(manager);
        vm.expectRevert(EPKVault.NotSessionManager.selector);
        vault.openSession(ENV, vm.addr(AGENT_A), vm.addr(AGENT_A), uint48(_now() + 1 hours));
        vm.prank(manager);
        vm.expectRevert(EPKVault.NotAdminOrGuardian.selector);
        vault.revokePolicy(0);
    }

    function test_panicKillsSessionsAndBlocksNewOnes() public {
        uint256 sid = _open(AGENT_A, 1 hours);
        vm.prank(guardian);
        vault.panic();
        vm.prank(manager);
        vm.expectRevert(EPKVault.IsPaused.selector);
        vault.openSession(ENV, vm.addr(AGENT_B), vm.addr(AGENT_B), uint48(_now() + 1 hours));

        bytes memory unpause = abi.encodeCall(EPKVault.unpause, ());
        vm.prank(admin);
        vault.schedule(unpause, bytes32(0));
        _warp(DELAY);
        vm.prank(admin);
        vault.executeScheduled(unpause, bytes32(0));
        _actFails(sid, AGENT_A, _pay(1e18), abi.encodeWithSelector(EPKVault.PolicyInactive.selector));
    }

    function test_sessionSignatureIsBoundToItsAgent() public {
        uint256 sid = _open(AGENT_A, 1 hours);
        EPKVault.Call[] memory calls = _pay(1e18);
        (bytes memory sig, uint256 deadline) = _signed(sid, AGENT_A, calls);
        vm.prank(vm.addr(AGENT_B));
        vm.expectRevert(EPKVault.AgentNotAllowed.selector);
        vault.execute(sid, calls, deadline, sig, "");
    }

    function test_ordinaryPoliciesAreUnaffected() public {
        assertEq(vault.budgetAvailable(0, address(token)), 0); // no policy 0 yet -> not a session
        uint256 sid = _open(AGENT_A, 1 hours);
        (,,,,,, uint64 env) = vault.policies(sid);
        assertEq(env, ENV + 1);
    }
}

/// Stateful: the session manager AND every session key are compromised. They open sessions at will
/// and spend as fast as they can. The vault-wide limit and each session's own budget still hold, and
/// only allowlisted destinations ever receive anything.
contract CompromisedManagerHandler is Test {
    EPKVault public vault;
    TestToken public token;
    address public manager;
    address public friend;
    address public attacker;

    uint256[] public pks;
    uint256[] public sids;
    uint256[] public openedAt;
    mapping(uint256 => uint256) public spentBy; // sid => total spent

    constructor(EPKVault v, TestToken t, address m, address f, address a) {
        vault = v;
        token = t;
        manager = m;
        friend = f;
        attacker = a;
    }

    function sessionCount() external view returns (uint256) {
        return sids.length;
    }

    function open(uint256 seed, uint256 ttl) external {
        if (sids.length >= 8) return;
        uint256 pk = uint256(keccak256(abi.encode("agent", sids.length, seed))) % 1e30 + 1;
        address agent = vm.addr(pk);
        vm.prank(manager);
        try vault.openSession(7, agent, agent, uint48(vm.getBlockTimestamp() + bound(ttl, 1, 2 days))) returns (uint256 sid) {
            pks.push(pk);
            sids.push(sid);
            openedAt.push(vm.getBlockTimestamp());
        } catch {}
    }

    function spend(uint256 which, uint256 amount, bool toAttacker) external {
        if (sids.length == 0) return;
        uint256 i = which % sids.length;
        amount = bound(amount, 1, 60e18);
        EPKVault.Call[] memory calls = new EPKVault.Call[](1);
        calls[0] = EPKVault.Call(
            address(token), 0, abi.encodeCall(IERC20.transfer, (toAttacker ? attacker : friend, amount))
        );
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 d = vault.getExecuteDigest(sids[i], vm.addr(pks[i]), calls, vault.nonces(sids[i]), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[i], d);
        vm.prank(vm.addr(pks[i]));
        try vault.execute(sids[i], calls, deadline, abi.encodePacked(r, s, v), "") {
            spentBy[sids[i]] += amount;
        } catch {}
    }

    function wait(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 0, 6 hours));
    }
}

contract EPKVaultSessionsInvariantTest is SessionBase {
    CompromisedManagerHandler handler;
    uint256 start;
    uint256 tokenStart;

    function setUp() public {
        _deploy();
        handler = new CompromisedManagerHandler(vault, token, manager, friend, attacker);
        targetContract(address(handler));
        start = _now();
        tokenStart = token.balanceOf(address(vault));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_vaultLimitHoldsWithManySessions() public view {
        uint256 elapsed = _now() - start;
        assertLe(tokenStart - token.balanceOf(address(vault)), VAULT_CAP + VAULT_CAP * elapsed / 1 days);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_eachSessionStaysWithinItsBudget() public view {
        uint256 n = handler.sessionCount();
        for (uint256 i = 0; i < n; i++) {
            uint256 sid = handler.sids(i);
            uint256 lived = _now() - handler.openedAt(i);
            assertLe(handler.spentBy(sid), SESSION_BUDGET + SESSION_BUDGET * lived / 1 days, "session over budget");
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_onlyAllowlistedDestinationsReceive() public view {
        assertEq(token.balanceOf(attacker), 0);
        assertEq(tokenStart - token.balanceOf(address(vault)), token.balanceOf(friend));
    }
}
