// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EPKVault} from "../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../contracts/v2/EPKVaultFactory.sol";
import {EPKRegistry} from "../../contracts/v2/EPKRegistry.sol";
import {MockTarget} from "./MockTarget.sol";
import {
    TestToken,
    FalseToken,
    MockRouter,
    Mock1271Wallet,
    EchoWallet,
    ReentrantTarget,
    RejectAllValidator
} from "./V2Mocks.sol";

contract EPKVaultTest is Test {
    EPKVaultFactory factory;
    EPKVault vault;
    TestToken token;
    TestToken untracked;
    FalseToken falseToken;
    MockTarget mockTarget;
    MockRouter router;
    ReentrantTarget reentrant;

    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address guardian2 = makeAddr("guardian2");
    address guardian3 = makeAddr("guardian3");
    address recoveryKey = makeAddr("recovery");
    address agent = makeAddr("agent");
    address agent2 = makeAddr("agent2");
    address friend = makeAddr("friend"); // allowed destination
    address attacker = makeAddr("attacker");

    uint256 signerPk = 0x51;
    address signer;
    uint256 coSignerPk = 0xC0;
    address coSigner;
    uint256 attackerPk = 0xBAD;

    uint256 pid;
    uint256 constant DELAY = 1 days;
    uint128 constant TOKEN_CAP = 100e18; // per day
    uint128 constant TOKEN_COSIGN = 50e18;
    uint128 constant NATIVE_CAP = 1 ether;

    function setUp() public {
        signer = vm.addr(signerPk);
        coSigner = vm.addr(coSignerPk);

        EPKVault impl = new EPKVault();
        EPKRegistry registry = new EPKRegistry(makeAddr("registryOwner"), address(impl));
        factory = new EPKVaultFactory(address(impl), address(registry));
        token = new TestToken("TKN");
        untracked = new TestToken("UNT");
        falseToken = new FalseToken();
        mockTarget = new MockTarget();
        router = new MockRouter();
        reentrant = new ReentrantTarget();

        vault = _newVault(admin, bytes32("main"));

        vm.startPrank(admin);
        vault.setAsset(address(token), TOKEN_CAP, 1 days, TOKEN_COSIGN);
        vault.setAsset(vault.NATIVE(), NATIVE_CAP, 1 days, type(uint128).max);
        vault.setAsset(address(falseToken), TOKEN_CAP, 1 days, type(uint128).max);
        vault.addDestination(friend);
        vault.addDestination(address(router));
        pid = vault.createPolicy(signer, 0, 1 ether, address(0));
        vault.setAgent(pid, agent, true, 0);
        vault.setAgent(pid, agent2, true, 0);
        vault.setCall(pid, address(token), IERC20.transfer.selector, true);
        vault.setCall(pid, address(token), IERC20.approve.selector, true);
        vault.setCall(pid, address(token), IERC20.transferFrom.selector, true);
        vault.setCall(pid, address(token), bytes4(0xa22cb465), true); // setApprovalForAll
        vault.setCall(pid, address(untracked), IERC20.transfer.selector, true);
        vault.setCall(pid, address(falseToken), IERC20.transfer.selector, true);
        vault.setCall(pid, address(router), MockRouter.pull.selector, true);
        vault.setCall(pid, address(reentrant), ReentrantTarget.attack.selector, true);
        vault.setCall(pid, friend, bytes4(0), true);
        vault.setCall(pid, attacker, bytes4(0), true); // call allowed, destination not: isolates that layer
        vault.setCall(pid, address(mockTarget), MockTarget.setX.selector, true);
        vault.setCoSigner(coSigner);
        vault.finalizeSetup();
        vm.stopPrank();

        token.mint(address(vault), 1_000e18);
        untracked.mint(address(vault), 1_000e18);
        vm.deal(address(vault), 10 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _newVault(address who, bytes32 salt) internal returns (EPKVault v) {
        address[] memory g = new address[](2);
        g[0] = guardian;
        g[1] = guardian2;
        vm.prank(who);
        v = EPKVault(payable(factory.createVault(g, DELAY, recoveryKey, salt)));
    }

    /// @dev Always read time through the cheatcode: with via_ir the optimizer may reuse a stale
    ///      `block.timestamp` inside one test function after vm.warp.
    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _deadline() internal view returns (uint256) {
        return _now() + 1 hours;
    }

    function _warp(uint256 secs) internal {
        vm.warp(_now() + secs);
    }

    function _one(address target, uint256 value, bytes memory data) internal pure returns (EPKVault.Call[] memory c) {
        c = new EPKVault.Call[](1);
        c[0] = EPKVault.Call(target, value, data);
    }

    function _digest(EPKVault v, uint256 policyId, address agent_, EPKVault.Call[] memory calls)
        internal
        view
        returns (bytes32)
    {
        return v.getExecuteDigest(policyId, agent_, calls, v.nonces(policyId), _deadline());
    }

    function _signDigest(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v_, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v_);
    }

    function _sig(EPKVault v, uint256 pk, uint256 policyId, address agent_, EPKVault.Call[] memory calls)
        internal
        view
        returns (bytes memory)
    {
        return _signDigest(pk, _digest(v, policyId, agent_, calls));
    }

    function _coSig(uint256 pk, EPKVault.Call[] memory calls) internal view returns (bytes memory) {
        return _signDigest(pk, vault.getCoSignDigest(_digest(vault, pid, agent, calls)));
    }

    /// @dev Signatures are prepared BEFORE expectRevert, so the expectation hits execute() itself.
    function _run(EPKVault.Call[] memory calls, uint256 coPk, bool fails, bytes memory err) internal {
        bytes memory sig = _sig(vault, signerPk, pid, agent, calls);
        bytes memory co = coPk == 0 ? bytes("") : _coSig(coPk, calls);
        uint256 deadline = _deadline();
        if (fails) {
            if (err.length == 0) vm.expectRevert();
            else vm.expectRevert(err);
        }
        vm.prank(agent);
        vault.execute(pid, calls, deadline, sig, co);
    }

    function _exec(address target, uint256 value, bytes memory data) internal {
        _run(_one(target, value, data), 0, false, "");
    }

    function _fails(bytes memory err, address target, uint256 value, bytes memory data) internal {
        _run(_one(target, value, data), 0, true, err);
    }

    function _transfer(address to, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeCall(IERC20.transfer, (to, amount));
    }

    function _approve(address spender, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeCall(IERC20.approve, (spender, amount));
    }

    function _schedule(bytes memory data) internal returns (bytes32 id) {
        vm.prank(admin);
        id = vault.schedule(data, bytes32(0));
    }

    function _activate(bytes memory op) internal {
        _schedule(op);
        _warp(DELAY);
        vm.prank(admin);
        vault.executeScheduled(op, bytes32(0));
    }

    // ------------------------------------------------------------------ happy path

    function test_transferToDestinationWorks() public {
        _exec(address(token), 0, _transfer(friend, 10e18));
        assertEq(token.balanceOf(friend), 10e18);
        assertEq(vault.availableToSpend(address(token)), TOKEN_CAP - 10e18);
    }

    function test_genericCallWorks() public {
        _exec(address(mockTarget), 0, abi.encodeCall(MockTarget.setX, (123)));
        assertEq(mockTarget.x(), 123);
    }

    /// The safe allowance pattern: approve -> use -> approve(0), in one signed batch.
    function test_batchApproveUseResetWorksAndIsCounted() public {
        EPKVault.Call[] memory calls = new EPKVault.Call[](3);
        calls[0] = EPKVault.Call(address(token), 0, _approve(address(router), 30e18));
        calls[1] = EPKVault.Call(
            address(router), 0, abi.encodeCall(MockRouter.pull, (address(token), address(vault), friend, 20e18))
        );
        calls[2] = EPKVault.Call(address(token), 0, _approve(address(router), 0));
        _run(calls, 0, false, "");

        assertEq(token.balanceOf(friend), 20e18);
        assertEq(token.allowance(address(vault), address(router)), 0);
        assertEq(vault.availableToSpend(address(token)), TOKEN_CAP - 20e18);
    }

    function test_erc1271SignerWorks() public {
        Mock1271Wallet wallet = new Mock1271Wallet(signer);
        _activate(abi.encodeCall(EPKVault.createPolicy, (address(wallet), 0, 0, address(0))));
        uint256 wpid = pid + 1;
        _activate(abi.encodeCall(EPKVault.setAgent, (wpid, agent, true, 0)));
        _activate(abi.encodeCall(EPKVault.setCall, (wpid, address(token), IERC20.transfer.selector, true)));

        EPKVault.Call[] memory calls = _one(address(token), 0, _transfer(friend, 1e18));
        bytes memory sig = _sig(vault, signerPk, wpid, agent, calls); // the wallet's owner signs
        uint256 deadline = _deadline();
        vm.prank(agent);
        vault.execute(wpid, calls, deadline, sig, "");
        assertEq(token.balanceOf(friend), 1e18);
    }

    // ------------------------------------------------------------------ isolation (no shared executor)

    function test_strangerCannotTouchAnotherCustomersVault() public {
        address strangerAdmin = makeAddr("strangerAdmin");
        EPKVault other = _newVault(strangerAdmin, bytes32("x"));
        vm.startPrank(strangerAdmin);
        other.setAsset(address(token), type(uint128).max, 1 days, type(uint128).max);
        other.addDestination(attacker);
        uint256 opid = other.createPolicy(vm.addr(attackerPk), 0, 0, address(0));
        other.setAgent(opid, attacker, true, 0);
        other.setCall(opid, address(token), IERC20.transferFrom.selector, true);
        other.finalizeSetup();
        vm.stopPrank();

        EPKVault.Call[] memory calls =
            _one(address(token), 0, abi.encodeCall(IERC20.transferFrom, (address(vault), attacker, 100e18)));
        bytes memory sig = _sig(other, attackerPk, opid, attacker, calls);
        uint256 deadline = _deadline();
        vm.prank(attacker);
        vm.expectRevert(); // the victim vault never left an allowance: nothing to take
        other.execute(opid, calls, deadline, sig, "");

        EPKVault.Call[] memory calls2 = _one(address(token), 0, _transfer(attacker, 1e18));
        bytes memory sig2 = _sig(vault, attackerPk, pid, attacker, calls2);
        vm.prank(attacker);
        vm.expectRevert(EPKVault.AgentNotAllowed.selector);
        vault.execute(pid, calls2, deadline, sig2, "");

        assertEq(token.balanceOf(attacker), 0);
    }

    // ------------------------------------------------------------------ destinations

    function test_transferToUnknownAddressBlocked() public {
        _fails(
            abi.encodeWithSelector(EPKVault.DestinationNotAllowed.selector, attacker),
            address(token),
            0,
            _transfer(attacker, 1e18)
        );
    }

    function test_nativeToUnknownAddressBlocked() public {
        _fails(abi.encodeWithSelector(EPKVault.DestinationNotAllowed.selector, attacker), attacker, 0.1 ether, "");
    }

    function test_approveToUnknownSpenderBlocked_evenAmountZero() public {
        bytes memory err = abi.encodeWithSelector(EPKVault.DestinationNotAllowed.selector, attacker);
        _fails(err, address(token), 0, _approve(attacker, 1e18));
        _fails(err, address(token), 0, _approve(attacker, 0)); // ERC-721 approve(x, 0) = token #0
        _exec(address(token), 0, _approve(friend, 0));
    }

    function test_untrackedAssetCannotMove() public {
        _fails(
            abi.encodeWithSelector(EPKVault.UntrackedAsset.selector, address(untracked)),
            address(untracked),
            0,
            _transfer(friend, 1e18)
        );
    }

    function testFuzz_neverPaysUnknownAddress(address to, uint96 amount) public {
        vm.assume(to != friend && to != address(router));
        _fails(
            abi.encodeWithSelector(EPKVault.DestinationNotAllowed.selector, to),
            address(token),
            0,
            _transfer(to, amount)
        );
    }

    // ------------------------------------------------------------------ approvals (review H-1)

    function test_allowanceCannotOutliveTheBatch() public {
        _fails(
            abi.encodeWithSelector(EPKVault.AllowanceLeft.selector, address(token), address(router)),
            address(token),
            0,
            _approve(address(router), 1_000e18)
        );

        // approve + partial use without reset also fails
        EPKVault.Call[] memory calls = new EPKVault.Call[](2);
        calls[0] = EPKVault.Call(address(token), 0, _approve(address(router), 30e18));
        calls[1] = EPKVault.Call(
            address(router), 0, abi.encodeCall(MockRouter.pull, (address(token), address(vault), friend, 10e18))
        );
        _run(calls, 0, true, abi.encodeWithSelector(EPKVault.AllowanceLeft.selector, address(token), address(router)));
        assertEq(token.allowance(address(vault), address(router)), 0);
    }

    function test_setApprovalForAllForbidden() public {
        _fails(
            abi.encodeWithSelector(EPKVault.ForbiddenApproval.selector),
            address(token),
            0,
            abi.encodeWithSelector(bytes4(0xa22cb465), friend, true)
        );
    }

    // ------------------------------------------------------------------ limits

    function test_limitPerWindowAndRefill() public {
        _exec(address(token), 0, _transfer(friend, 50e18));
        _exec(address(token), 0, _transfer(friend, 50e18));
        _fails(
            abi.encodeWithSelector(EPKVault.LimitExceeded.selector, address(token), 1e18, 0),
            address(token),
            0,
            _transfer(friend, 1e18)
        );

        _warp(12 hours); // half the window refills half the cap
        assertEq(vault.availableToSpend(address(token)), 50e18);
        _exec(address(token), 0, _transfer(friend, 50e18));
    }

    function test_nativeLimit() public {
        _exec(friend, 0.6 ether, "");
        _fails(
            abi.encodeWithSelector(EPKVault.LimitExceeded.selector, address(0), 0.6 ether, 0.4 ether),
            friend,
            0.6 ether,
            ""
        );
    }

    function test_valuePerCallCap() public {
        _fails(abi.encodeWithSelector(EPKVault.ValueTooHigh.selector), friend, 1.1 ether, "");
    }

    /// Outflow is measured on real balances: a "hidden" pull through an allowed contract counts too.
    function test_hiddenOutflowThroughRouterIsCounted() public {
        EPKVault.Call[] memory calls = new EPKVault.Call[](3);
        calls[0] = EPKVault.Call(address(token), 0, _approve(address(router), 150e18));
        calls[1] = EPKVault.Call(
            address(router), 0, abi.encodeCall(MockRouter.pull, (address(token), address(vault), attacker, 150e18))
        );
        calls[2] = EPKVault.Call(address(token), 0, _approve(address(router), 0));
        _run(
            calls,
            coSignerPk,
            true,
            abi.encodeWithSelector(EPKVault.LimitExceeded.selector, address(token), 150e18, TOKEN_CAP)
        );
    }

    function test_tokenReturningFalseReverts() public {
        _fails(
            abi.encodeWithSelector(EPKVault.TokenCallFailed.selector, address(falseToken)),
            address(falseToken),
            0,
            _transfer(friend, 1e18)
        );
    }

    // ------------------------------------------------------------------ co-signer

    function test_largeTransferNeedsCoSigner() public {
        EPKVault.Call[] memory calls = _one(address(token), 0, _transfer(friend, 60e18));
        bytes memory err = abi.encodeWithSelector(EPKVault.CoSignatureRequired.selector, address(token), 60e18);
        _run(calls, 0, true, err);
        _run(calls, attackerPk, true, err); // wrong co-signer

        _run(calls, coSignerPk, false, "");
        assertEq(token.balanceOf(friend), 60e18);
    }

    /// Review I-1: the co-signer must sign its own digest; a signature on the operator digest is not enough.
    function test_coSignatureUsesSeparateDigest() public {
        EPKVault.Call[] memory calls = _one(address(token), 0, _transfer(friend, 60e18));
        bytes memory sig = _sig(vault, signerPk, pid, agent, calls);
        bytes memory wrongCo = _sig(vault, coSignerPk, pid, agent, calls); // signs the execute digest
        uint256 deadline = _deadline();
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.CoSignatureRequired.selector, address(token), 60e18));
        vault.execute(pid, calls, deadline, sig, wrongCo);
    }

    // ------------------------------------------------------------------ signatures

    function test_replayRejected() public {
        EPKVault.Call[] memory calls = _one(address(token), 0, _transfer(friend, 1e18));
        bytes memory sig = _sig(vault, signerPk, pid, agent, calls);
        uint256 deadline = _deadline();
        vm.prank(agent);
        vault.execute(pid, calls, deadline, sig, "");
        vm.prank(agent);
        vm.expectRevert(EPKVault.BadSignature.selector);
        vault.execute(pid, calls, deadline, sig, "");
    }

    /// Review I-6: the signature names the agent; another allowed agent cannot use it.
    function test_signatureBoundToAgent() public {
        EPKVault.Call[] memory calls = _one(address(token), 0, _transfer(friend, 1e18));
        bytes memory sig = _sig(vault, signerPk, pid, agent, calls);
        uint256 deadline = _deadline();
        vm.prank(agent2);
        vm.expectRevert(EPKVault.BadSignature.selector);
        vault.execute(pid, calls, deadline, sig, "");
    }

    /// Review I-6: revoking a policy kills signatures that were already queued for it.
    function test_revokePolicyKillsQueuedSignatures() public {
        EPKVault.Call[] memory calls = _one(address(token), 0, _transfer(friend, 1e18));
        bytes memory sig = _sig(vault, signerPk, pid, agent, calls);
        uint256 deadline = _now() + 3 days;
        bytes32 digest = vault.getExecuteDigest(pid, agent, calls, vault.nonces(pid), deadline);
        sig = _signDigest(signerPk, digest);

        vm.prank(guardian);
        vault.revokePolicy(pid);
        _activate(abi.encodeCall(EPKVault.setPolicyActive, (pid, true)));

        vm.prank(agent);
        vm.expectRevert(EPKVault.BadSignature.selector);
        vault.execute(pid, calls, deadline, sig, "");
    }

    /// Review L-1: a contract that echoes calldata is not a valid ERC-1271 signer.
    function test_echoContractIsNotAValidSigner() public {
        EchoWallet echo = new EchoWallet();
        EPKVault v = _newVault(admin, bytes32("echo"));
        vm.startPrank(admin);
        v.setAsset(address(token), TOKEN_CAP, 1 days, type(uint128).max);
        v.addDestination(friend);
        uint256 p = v.createPolicy(address(echo), 0, 0, address(0));
        v.setAgent(p, agent, true, 0);
        v.setCall(p, address(token), IERC20.transfer.selector, true);
        v.finalizeSetup();
        vm.stopPrank();
        token.mint(address(v), 10e18);

        EPKVault.Call[] memory calls = _one(address(token), 0, _transfer(friend, 1e18));
        uint256 deadline = _deadline();
        vm.prank(agent);
        vm.expectRevert(EPKVault.BadSignature.selector);
        v.execute(p, calls, deadline, hex"deadbeef", "");
    }

    function test_cannotTargetVaultItself() public {
        _fails(
            abi.encodeWithSelector(EPKVault.BadTarget.selector),
            address(vault),
            0,
            abi.encodeCall(EPKVault.addDestination, (attacker))
        );
    }

    /// Review L-2: the native-transfer permission cannot carry calldata with a zero selector.
    function test_zeroSelectorWithDataRejected() public {
        _fails(abi.encodeWithSelector(EPKVault.BadCalldata.selector), friend, 0, abi.encodePacked(bytes4(0), uint256(1)));
    }

    function test_reentrancyBlocked() public {
        _fails(
            abi.encodeWithSelector(EPKVault.Reentrancy.selector),
            address(reentrant),
            0,
            abi.encodeCall(ReentrantTarget.attack, (address(vault)))
        );
    }

    // ------------------------------------------------------------------ timelock & roles

    function test_afterSetupLooseningNeedsTimelock() public {
        vm.prank(admin);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        vault.addDestination(attacker);

        bytes memory op = abi.encodeCall(EPKVault.addDestination, (attacker));
        _schedule(op);
        vm.prank(admin);
        vm.expectRevert(EPKVault.OperationNotReady.selector);
        vault.executeScheduled(op, bytes32(0));

        _warp(DELAY);
        vm.prank(admin);
        vault.executeScheduled(op, bytes32(0));
        assertTrue(vault.isDestination(attacker));
    }

    function test_guardianVetoesPendingChange() public {
        bytes memory op = abi.encodeCall(EPKVault.addDestination, (attacker));
        bytes32 id = _schedule(op);
        vm.prank(guardian);
        vault.cancel(id);
        _warp(DELAY);
        vm.prank(admin);
        vm.expectRevert(EPKVault.UnknownOperation.selector);
        vault.executeScheduled(op, bytes32(0));
    }

    function test_staleAfterGracePeriod() public {
        bytes memory op = abi.encodeCall(EPKVault.addDestination, (attacker));
        _schedule(op);
        _warp(DELAY + vault.GRACE_PERIOD() + 1);
        vm.prank(admin);
        vm.expectRevert(EPKVault.StaleOperation.selector);
        vault.executeScheduled(op, bytes32(0));
    }

    function test_guardianCanOnlyStop() public {
        vm.startPrank(guardian);
        vm.expectRevert(EPKVault.NotAdmin.selector);
        vault.schedule(abi.encodeCall(EPKVault.unpause, ()), bytes32(0));
        vault.pause();
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        vault.unpause();
        vm.expectRevert(EPKVault.NotAdminOrRecovery.selector);
        vault.executeScheduled(abi.encodeCall(EPKVault.unpause, ()), bytes32(0));
        vm.stopPrank();

        _fails(abi.encodeWithSelector(EPKVault.IsPaused.selector), address(token), 0, _transfer(friend, 1e18));
    }

    function test_panicKillsPoliciesAndPendingChanges_rescheduleWorks() public {
        bytes memory op = abi.encodeCall(EPKVault.addDestination, (attacker));
        _schedule(op);

        vm.prank(guardian);
        vault.panic();

        _warp(DELAY);
        vm.prank(admin);
        vm.expectRevert(EPKVault.StaleOperation.selector);
        vault.executeScheduled(op, bytes32(0));

        // Review I-2: the same operation can be scheduled again after a panic.
        _schedule(op);

        // Even after a legit unpause, old policies stay dead.
        _activate(abi.encodeCall(EPKVault.unpause, ()));
        _fails(
            abi.encodeWithSelector(EPKVault.PolicyInactive.selector), address(token), 0, _transfer(friend, 1e18)
        );
    }

    function test_lowerLimitInstantly_raiseOnlyViaTimelock() public {
        vm.prank(guardian);
        vault.lowerAssetLimit(address(token), 10e18, 5e18);
        assertEq(vault.availableToSpend(address(token)), 10e18);

        vm.prank(guardian);
        vm.expectRevert(EPKVault.NotTighter.selector);
        vault.lowerAssetLimit(address(token), 20e18, 5e18);

        vm.prank(admin);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        vault.setAsset(address(token), 1_000e18, 1 days, 500e18);
    }

    /// Review I-4: an asset added after setup starts with an empty bucket.
    function test_assetAddedAfterSetupStartsEmpty() public {
        _activate(abi.encodeCall(EPKVault.setAsset, (address(untracked), 100e18, 1 days, type(uint128).max)));
        assertEq(vault.availableToSpend(address(untracked)), 0);
        _warp(12 hours);
        assertEq(vault.availableToSpend(address(untracked)), 50e18);
    }

    function test_noExecutionBeforeSetupFinished() public {
        EPKVault fresh = _newVault(admin, bytes32("f"));
        EPKVault.Call[] memory calls = _one(address(token), 0, "");
        uint256 deadline = _deadline();
        vm.prank(agent);
        vm.expectRevert(EPKVault.SetupNotFinished.selector);
        fresh.execute(0, calls, deadline, "", "");
    }

    function test_finalizeNeedsTwoGuardians_adminIsNeverGuardian() public {
        address[] memory one = new address[](1);
        one[0] = guardian;
        vm.prank(admin);
        EPKVault v = EPKVault(payable(factory.createVault(one, DELAY, address(0), bytes32("1g"))));
        vm.prank(admin);
        vm.expectRevert(EPKVault.TooFewGuardians.selector);
        v.finalizeSetup();

        address[] memory self = new address[](1);
        self[0] = admin;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.BadRole.selector, admin));
        factory.createVault(self, DELAY, address(0), bytes32("self"));
    }

    function test_cannotSetVaultAsAdminOrTarget() public {
        EPKVault fresh = _newVault(admin, bytes32("g"));
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.BadRole.selector, address(fresh)));
        fresh.setAdmin(address(fresh));
        uint256 p = fresh.createPolicy(signer, 0, 0, address(0));
        vm.expectRevert(EPKVault.BadTarget.selector);
        fresh.setCall(p, address(fresh), EPKVault.addDestination.selector, true);
        vm.stopPrank();
    }

    function test_badDelayRejected() public {
        vm.expectRevert(EPKVault.BadDelay.selector);
        factory.createVault(new address[](0), 10 minutes, address(0), bytes32("d"));
    }

    // ------------------------------------------------------------------ rogue guardian (review M-1)

    function test_rogueGuardianCannotFreezeForever() public {
        // guardian goes rogue: panics and vetoes every unpause
        vm.prank(guardian);
        vault.panic();
        bytes memory unpause = abi.encodeCall(EPKVault.unpause, ());
        bytes32 uid = _schedule(unpause);
        vm.prank(guardian);
        vault.cancel(uid);

        // admin replaces the rogue guardian: it can neither veto nor kill that operation
        bytes memory replace = abi.encodeCall(EPKVault.replaceGuardian, (guardian, guardian3));
        bytes32 rid = _schedule(replace);
        vm.prank(guardian);
        vm.expectRevert(EPKVault.CannotCancel.selector);
        vault.cancel(rid);
        vm.prank(guardian);
        vault.revokeAll();

        _warp(DELAY);
        vm.prank(admin);
        vault.executeScheduled(replace, bytes32(0));
        assertFalse(vault.isGuardian(guardian));
        assertTrue(vault.isGuardian(guardian3));

        // the former guardian has no power left; unpause goes through
        _schedule(unpause);
        vm.prank(guardian);
        vm.expectRevert(EPKVault.NotAdminOrGuardian.selector);
        vault.cancel(uid);
        _warp(DELAY);
        vm.prank(admin);
        vault.executeScheduled(unpause, bytes32(0));
        assertFalse(vault.paused());
    }

    function test_guardianCountCannotDropBelowMinimum() public {
        bytes memory op = abi.encodeCall(EPKVault.setGuardian, (guardian, false));
        _schedule(op);
        _warp(DELAY);
        vm.prank(admin);
        vm.expectRevert(EPKVault.TooFewGuardians.selector);
        vault.executeScheduled(op, bytes32(0));
    }

    // ------------------------------------------------------------------ admin recovery (review M-2)

    function test_recoveryReplacesLostOrStolenAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(recoveryKey);
        bytes32 id = vault.recoverAdmin(newAdmin, bytes32(0));

        // a compromised admin can neither cancel nor panic it away
        vm.prank(admin);
        vm.expectRevert(EPKVault.CannotCancel.selector);
        vault.cancel(id);
        vm.prank(admin);
        vault.panic();

        _warp(DELAY); // recovery takes twice the delay
        bytes memory op = abi.encodeCall(EPKVault.setAdmin, (newAdmin));
        vm.prank(recoveryKey);
        vm.expectRevert(EPKVault.OperationNotReady.selector);
        vault.executeScheduled(op, bytes32(0));

        _warp(DELAY);
        vm.prank(recoveryKey);
        vault.executeScheduled(op, bytes32(0));
        assertEq(vault.admin(), newAdmin);
    }

    function test_guardianCanVetoStolenRecoveryKey() public {
        vm.prank(recoveryKey);
        bytes32 id = vault.recoverAdmin(attacker, bytes32(0));
        vm.prank(guardian2);
        vault.cancel(id);
        _warp(2 * DELAY);
        vm.prank(recoveryKey);
        vm.expectRevert(EPKVault.UnknownOperation.selector);
        vault.executeScheduled(abi.encodeCall(EPKVault.setAdmin, (attacker)), bytes32(0));
    }

    // ------------------------------------------------------------------ factory (review L-5)

    function test_factoryCallerIsAdmin_predictsAddress() public {
        address[] memory g = new address[](2);
        g[0] = guardian;
        g[1] = guardian2;
        address predicted = factory.predictVaultAddress(attacker, g, DELAY, address(0), bytes32("p"));
        vm.prank(attacker);
        address created = factory.createVault(g, DELAY, address(0), bytes32("p"));
        assertEq(created, predicted);
        assertTrue(factory.isVault(created));
        assertEq(EPKVault(payable(created)).admin(), attacker); // nobody can make a vault "for" someone else

        vm.prank(admin);
        address other = factory.createVault(g, DELAY, address(0), bytes32("p"));
        assertTrue(other != created);
    }

    // ------------------------------------------------------------------ edge cases & admin paths

    function _expectExec(
        uint256 policyId,
        address agent_,
        EPKVault.Call[] memory calls,
        uint256 deadline,
        bytes memory err
    ) internal {
        bytes32 d = vault.getExecuteDigest(policyId, agent_, calls, vault.nonces(policyId), deadline);
        bytes memory sig = _signDigest(signerPk, d);
        vm.expectRevert(err);
        vm.prank(agent_);
        vault.execute(policyId, calls, deadline, sig, "");
    }

    function test_deadlineAndTtlChecks() public {
        EPKVault.Call[] memory calls = _one(address(token), 0, _transfer(friend, 1e18));
        _expectExec(pid, agent, calls, 0, abi.encodeWithSelector(EPKVault.DeadlineRequired.selector));
        _expectExec(pid, agent, calls, _now(), abi.encodeWithSelector(EPKVault.Expired.selector));

        address shortAgent = makeAddr("shortAgent");
        _activate(abi.encodeCall(EPKVault.setAgent, (pid, shortAgent, true, uint40(_now() + 2 days))));
        _warp(2 days);
        _expectExec(pid, shortAgent, calls, _deadline(), abi.encodeWithSelector(EPKVault.AgentExpired.selector));

        _activate(abi.encodeCall(EPKVault.updatePolicy, (pid, signer, uint48(_now() + 1 days), 1 ether, address(0))));
        _exec(address(token), 0, _transfer(friend, 1e18)); // still valid at the boundary
        _warp(1);
        _expectExec(pid, agent, calls, _deadline(), abi.encodeWithSelector(EPKVault.Expired.selector));
    }

    function test_tighteningFunctions() public {
        EPKVault.Call[] memory calls = _one(address(token), 0, _transfer(friend, 1e18));
        bytes memory queued = _sig(vault, signerPk, pid, agent, calls);
        uint256 deadline = _deadline();

        vm.startPrank(guardian);
        vault.revokeAgent(pid, agent2);
        vault.disallowCall(pid, address(mockTarget), MockTarget.setX.selector);
        vault.removeDestination(address(router));
        vault.bumpNonce(pid, 5);
        vm.expectRevert(EPKVault.NonceTooLow.selector);
        vault.bumpNonce(pid, 5);
        vm.expectRevert(EPKVault.NonceTooLow.selector);
        vault.bumpNonce(pid, type(uint256).max);
        vm.stopPrank();

        (bool allowed,) = vault.agentPermission(pid, agent2);
        assertFalse(allowed);
        _fails(
            abi.encodeWithSelector(EPKVault.CallNotAllowed.selector),
            address(mockTarget),
            0,
            abi.encodeCall(MockTarget.setX, (1))
        );
        _fails(
            abi.encodeWithSelector(EPKVault.DestinationNotAllowed.selector, address(router)),
            address(token),
            0,
            _approve(address(router), 1)
        );
        vm.prank(agent);
        vm.expectRevert(EPKVault.BadSignature.selector); // queued signature killed by the nonce bump
        vault.execute(pid, calls, deadline, queued, "");
    }

    function test_adminChangesViaTimelock() public {
        address newRecovery = makeAddr("newRecovery");
        _activate(abi.encodeCall(EPKVault.updatePolicy, (pid, signer, 0, 2 ether, address(0))));
        bytes memory newRec = abi.encodeCall(EPKVault.setRecovery, (newRecovery));
        _schedule(newRec);
        _warp(3 * DELAY); // a recovery change waits 3 x delay (2.2.0)
        vm.prank(admin);
        vault.executeScheduled(newRec, bytes32(0));
        _activate(abi.encodeCall(EPKVault.setCoSigner, (address(0))));
        _activate(abi.encodeCall(EPKVault.setGuardian, (guardian3, true)));
        _activate(abi.encodeCall(EPKVault.untrackAsset, (address(falseToken))));
        _activate(abi.encodeCall(EPKVault.setDelay, (2 days)));

        (,,,, uint128 maxValue,,,) = vault.policies(pid);
        assertEq(maxValue, 2 ether);
        assertEq(vault.recovery(), newRecovery);
        assertEq(vault.coSigner(), address(0));
        assertTrue(vault.isGuardian(guardian3));
        assertEq(vault.guardianCount(), 3);
        assertEq(vault.trackedAssets().length, 2);
        assertEq(vault.delay(), 2 days);

        vm.prank(admin);
        vm.expectRevert(EPKVault.NotTimelocked.selector); // direct loosening after setup is refused
        vault.setDelay(1 days);

        EPKVault fresh = _newVault(admin, bytes32("delay"));
        vm.prank(admin);
        vm.expectRevert(EPKVault.BadDelay.selector);
        fresh.setDelay(1);
    }

    function test_noCoSignerMeansLargeOutflowImpossible() public {
        _activate(abi.encodeCall(EPKVault.setCoSigner, (address(0))));
        _run(
            _one(address(token), 0, _transfer(friend, 60e18)),
            coSignerPk,
            true,
            abi.encodeWithSelector(EPKVault.CoSignatureRequired.selector, address(token), 60e18)
        );
    }

    function test_validatorCanReject() public {
        RejectAllValidator rej = new RejectAllValidator();
        _activate(abi.encodeCall(EPKVault.updatePolicy, (pid, signer, 0, 1 ether, address(rej))));
        _fails(
            abi.encodeWithSelector(RejectAllValidator.Rejected.selector), address(token), 0, _transfer(friend, 1e18)
        );
    }

    function test_transferFromToUnknownBlocked() public {
        _fails(
            abi.encodeWithSelector(EPKVault.DestinationNotAllowed.selector, attacker),
            address(token),
            0,
            abi.encodeCall(IERC20.transferFrom, (friend, attacker, 1e18))
        );
    }

    function test_batchSizeLimits() public {
        bytes memory err = abi.encodeWithSelector(EPKVault.BadCalldata.selector);
        _run(new EPKVault.Call[](0), 0, true, err);
        EPKVault.Call[] memory many = new EPKVault.Call[](17);
        for (uint256 i = 0; i < 17; i++) {
            many[i] = EPKVault.Call(address(mockTarget), 0, abi.encodeCall(MockTarget.setX, (i)));
        }
        _run(many, 0, true, err);
    }

    function test_signatureNotValidOnAnotherChain() public {
        EPKVault.Call[] memory calls = _one(address(token), 0, _transfer(friend, 1e18));
        bytes memory sig = _sig(vault, signerPk, pid, agent, calls);
        uint256 deadline = _deadline();
        bytes32 ds = vault.domainSeparator();
        vm.chainId(999);
        assertTrue(vault.domainSeparator() != ds);
        vm.prank(agent);
        vm.expectRevert(EPKVault.BadSignature.selector);
        vault.execute(pid, calls, deadline, sig, "");
    }

    function test_scheduleAndRoleErrors() public {
        bytes memory op = abi.encodeCall(EPKVault.addDestination, (attacker));
        vm.startPrank(admin);
        vm.expectRevert(EPKVault.BadOperation.selector);
        vault.schedule(hex"01", bytes32(0));
        vault.schedule(op, bytes32(0));
        vm.expectRevert(EPKVault.OperationExists.selector);
        vault.schedule(op, bytes32(0));
        vm.expectRevert(EPKVault.UnknownOperation.selector);
        vault.cancel(bytes32(uint256(1)));
        vm.expectRevert(EPKVault.UnknownOperation.selector);
        vault.executeScheduled(abi.encodeCall(EPKVault.unpause, ()), bytes32(0));
        vm.expectRevert(EPKVault.SetupAlreadyFinished.selector);
        vault.finalizeSetup();
        vm.stopPrank();

        vm.startPrank(attacker);
        vm.expectRevert(EPKVault.NotAdmin.selector);
        vault.schedule(op, bytes32("x"));
        vm.expectRevert(EPKVault.NotAdminOrGuardian.selector);
        vault.pause();
        vm.expectRevert(EPKVault.NotRecovery.selector);
        vault.recoverAdmin(attacker, bytes32(0));
        vm.stopPrank();
    }

    function test_assetConfigErrors() public {
        EPKVault v = _newVault(admin, bytes32("assets"));
        vm.startPrank(admin);
        for (uint160 i = 1; i <= 16; i++) {
            v.setAsset(address(i + 1000), 1, 1, 1);
        }
        vm.expectRevert(EPKVault.TooManyAssets.selector);
        v.setAsset(address(5000), 1, 1, 1);
        vm.expectRevert(EPKVault.BadOperation.selector);
        v.setAsset(address(1001), 1, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.UntrackedAsset.selector, address(7000)));
        v.untrackAsset(address(7000));
        vm.expectRevert(abi.encodeWithSelector(EPKVault.UntrackedAsset.selector, address(7000)));
        v.lowerAssetLimit(address(7000), 0, 0);
        vm.stopPrank();
        assertEq(v.availableToSpend(address(7000)), 0);
    }

    function test_constructorRoleChecks() public {
        address[] memory g = new address[](2);
        g[0] = guardian;
        g[1] = guardian;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.BadRole.selector, guardian));
        factory.createVault(g, DELAY, address(0), bytes32("dup"));

        g[1] = address(0);
        vm.prank(admin);
        vm.expectRevert(EPKVault.ZeroAddress.selector);
        factory.createVault(g, DELAY, address(0), bytes32("zero"));

        g[1] = guardian2;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.BadRole.selector, admin));
        factory.createVault(g, DELAY, admin, bytes32("rec"));
    }

    function test_roleSeparationChecks() public {
        EPKVault v = _newVault(admin, bytes32("rg"));
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.BadRole.selector, attacker));
        v.replaceGuardian(attacker, guardian3);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.BadRole.selector, guardian2));
        v.replaceGuardian(guardian, guardian2);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.BadRole.selector, admin));
        v.replaceGuardian(guardian, admin);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.BadRole.selector, admin));
        v.setGuardian(admin, true);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.BadRole.selector, guardian));
        v.setAdmin(guardian);
        vm.expectRevert(abi.encodeWithSelector(EPKVault.BadRole.selector, guardian));
        v.setRecovery(guardian);
        v.replaceGuardian(guardian, guardian3);
        v.setGuardian(guardian3, true); // already a guardian: no-op
        vm.stopPrank();
        assertTrue(v.isGuardian(guardian3));
        assertFalse(v.isGuardian(guardian));
        assertEq(v.guardianCount(), 2);
    }

    // ------------------------------------------------------------------ the main promise

    /// Signer, agent AND co-signer fully compromised: total outflow over any period T is still
    /// bounded by cap + cap * T / window, and only allowlisted destinations receive anything.
    function testFuzz_compromisedOperatorCannotDrain(uint256 seed) public {
        uint256 start = _now();
        uint256 sent;
        for (uint256 i = 0; i < 25; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            _warp(seed % 12 hours);
            uint256 amount = (seed >> 64) % 200e18;

            EPKVault.Call[] memory calls = _one(address(token), 0, _transfer(friend, amount));
            bytes memory sig = _sig(vault, signerPk, pid, agent, calls);
            bytes memory co = _coSig(coSignerPk, calls);
            uint256 deadline = _deadline();
            vm.prank(agent);
            try vault.execute(pid, calls, deadline, sig, co) {
                sent += amount;
            } catch {}
        }
        uint256 elapsed = _now() - start;
        assertLe(sent, uint256(TOKEN_CAP) + uint256(TOKEN_CAP) * elapsed / 1 days);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(token.balanceOf(friend), sent);
    }

    // ------------------------------------------------------------------ fifth review (2026-11-08), fixed in 2.2.0

    /// A5-3: a stolen recovery key used to be able to veto every change, including its own replacement, and
    /// so keep a paused vault paused forever. Since 2.2.0 replacing the recovery key is shielded from it.
    function test_recoveryCannotVetoItsOwnReplacement() public {
        vm.prank(guardian);
        vault.panic();
        address fresh = makeAddr("freshRecovery");
        bytes memory replace = abi.encodeCall(EPKVault.setRecovery, (fresh));
        bytes32 id = _schedule(replace);
        vm.prank(recoveryKey);
        vm.expectRevert(EPKVault.CannotCancel.selector);
        vault.cancel(id);
        _warp(DELAY); // a recovery change waits 3 x delay (longer than recoverAdmin's 2 x)
        vm.prank(admin);
        vm.expectRevert(EPKVault.OperationNotReady.selector);
        vault.executeScheduled(replace, bytes32(0));
        _warp(2 * DELAY);
        vm.prank(admin);
        vault.executeScheduled(replace, bytes32(0));
        assertEq(vault.recovery(), fresh);

        // the old key has no say any more: the owner resumes the vault
        bytes memory resume = abi.encodeCall(EPKVault.unpause, ());
        bytes32 id2 = _schedule(resume);
        vm.prank(recoveryKey);
        vm.expectRevert(EPKVault.NotAdminOrGuardian.selector);
        vault.cancel(id2);
        _warp(DELAY);
        vm.prank(admin);
        vault.executeScheduled(resume, bytes32(0));
        assertFalse(vault.paused());
    }

    /// The shield only removes the replaced key's own veto: guardians can still stop a recovery change
    /// (e.g. one scheduled with a stolen admin key).
    function test_guardianCanStillVetoARecoveryChange() public {
        bytes32 id = _schedule(abi.encodeCall(EPKVault.setRecovery, (attacker)));
        vm.prank(guardian);
        vault.cancel(id);
        _warp(DELAY);
        vm.prank(admin);
        vm.expectRevert(EPKVault.UnknownOperation.selector);
        vault.executeScheduled(abi.encodeCall(EPKVault.setRecovery, (attacker)), bytes32(0));
        assertEq(vault.recovery(), recoveryKey);
    }

    /// The other side of the shield: with the admin key stolen and every guardian away, an honest recovery
    /// key still wins — its recoverAdmin (2 x delay) lands before the attacker's recovery change (3 x delay),
    /// and the new admin cancels that change.
    function test_honestRecoveryBeatsCompromisedAdmin() public {
        bytes memory replace = abi.encodeCall(EPKVault.setRecovery, (attacker));
        bytes32 id = _schedule(replace); // scheduled with the stolen admin key
        address newAdmin = makeAddr("newAdmin");
        vm.prank(recoveryKey);
        vault.recoverAdmin(newAdmin, bytes32("rescue"));
        _warp(2 * DELAY);
        vm.prank(recoveryKey);
        vault.executeScheduled(abi.encodeCall(EPKVault.setAdmin, (newAdmin)), bytes32("rescue"));
        assertEq(vault.admin(), newAdmin);
        vm.prank(newAdmin);
        vault.cancel(id);
        _warp(DELAY);
        vm.prank(newAdmin);
        vm.expectRevert(EPKVault.UnknownOperation.selector);
        vault.executeScheduled(replace, bytes32(0));
        assertEq(vault.recovery(), recoveryKey);
    }

    /// A panic invalidates a pending recovery change (only guardian removals survive a panic).
    function test_panicCancelsARecoveryChange() public {
        bytes memory replace = abi.encodeCall(EPKVault.setRecovery, (attacker));
        _schedule(replace);
        vm.prank(guardian);
        vault.panic();
        _warp(3 * DELAY);
        vm.prank(admin);
        vm.expectRevert(EPKVault.StaleOperation.selector);
        vault.executeScheduled(replace, bytes32(0));
        assertEq(vault.recovery(), recoveryKey);
    }

    /// A5-4: an ERC-721 `approve(destination, 0)` approves token #0. Since 2.2.0 every approval is recorded
    /// and checked after the batch; an NFT has no `allowance()`, so the batch fails closed.
    function test_nftApprovalOfTokenZeroFailsClosed() public {
        AuditNFT nft = new AuditNFT();
        nft.mint(address(vault), 0);
        _activate(abi.encodeCall(EPKVault.setCall, (pid, address(nft), IERC20.approve.selector, true)));
        _fails("", address(nft), 0, abi.encodeCall(IERC20.approve, (address(router), 0)));
        assertEq(nft.getApproved(0), address(0));
        vm.prank(address(router));
        vm.expectRevert(bytes("not allowed"));
        nft.transferFrom(address(vault), attacker, 0);
    }

    /// Resetting an ERC-20 allowance to zero (the normal end of a swap batch) still works.
    function test_erc20AllowanceResetStillWorks() public {
        EPKVault.Call[] memory c = new EPKVault.Call[](2);
        c[0] = EPKVault.Call(address(token), 0, _approve(address(router), 1e18));
        c[1] = EPKVault.Call(address(token), 0, _approve(address(router), 0));
        _run(c, 0, false, "");
        assertEq(token.allowance(address(vault), address(router)), 0);
    }

    /// An approval to address(0) is refused (it is never a destination).
    function test_approvalToZeroAddressIsRefused() public {
        _fails(abi.encodeWithSelector(EPKVault.DestinationNotAllowed.selector, address(0)), address(token), 0, _approve(address(0), 0));
    }
}

/// Minimal ERC-721 (approve / getApproved / transferFrom / ownerOf) for the A5-4 tests.
contract AuditNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public getApproved;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function approve(address to, uint256 id) external {
        require(msg.sender == ownerOf[id], "not owner");
        getApproved[id] = to;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && (msg.sender == from || msg.sender == getApproved[id]), "not allowed");
        ownerOf[id] = to;
        getApproved[id] = address(0);
    }
}
