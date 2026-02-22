// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import "./EPKernel.t.sol";

contract EPKernelCoverageExtraTest is EPKernelTest {
    uint256 internal policyId;
    uint256 internal value = 1;

    function _digest(uint256 pid, address tgt, uint256 val, bytes memory data, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return kernel.getTypedDataHash(pid, tgt, val, keccak256(data), nonce, deadline);
    }

    function testEmergencyNonceBump_owner_success_andOldSigFails() public {
        policyId = _createBasicPolicy(address(0));
        bytes memory data = abi.encodeCall(MockTarget.setX, (12345));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sigOld = _signCurrentNonce(policyId, address(target), 0, data, deadline);
        uint256 cur = kernel.nonces(policyId);
        vm.prank(owner);
        kernel.emergencyNonceBump(policyId, cur + 7);
        vm.prank(agent);
        vm.expectRevert(EPKernel.BadSignature.selector);
        kernel.execute(policyId, address(target), 0, data, deadline, sigOld);
        bytes memory sigNew = _signCurrentNonce(policyId, address(target), 0, data, deadline);
        vm.prank(agent);
        kernel.execute(policyId, address(target), 0, data, deadline, sigNew);
        assertEq(target.x(), 12345);
    }

    function testEmergencyNonceBump_owner_revertsWhenNotIncreasing() public {
        policyId = _createBasicPolicy(address(0));
        uint256 cur = kernel.nonces(policyId);
        vm.prank(owner);
        vm.expectRevert();
        kernel.emergencyNonceBump(policyId, cur);
    }

    function testExecute_badSignature_sigLen64_hitsRecoverBranch() public {
        policyId = _createBasicPolicy(address(0));
        bytes memory data = abi.encodeCall(MockTarget.setX, (1));
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 dataHash = keccak256(data);
        uint256 nonce = kernel.nonces(policyId);
        bytes32 digest = kernel.getTypedDataHash(policyId, address(target), value, dataHash, nonce, deadline);
        bytes memory sig = new bytes(64);
        assembly {
            mstore(add(sig, 32), digest)
            mstore(add(sig, 64), digest)
        }
        vm.prank(agent);
        vm.expectRevert(EPKernel.BadSignature.selector);
        kernel.execute(policyId, address(target), 0, data, deadline, sig);
    }

    function testExecute_badSignature_sigLen0_hitsRecoverBranch() public {
        policyId = _createBasicPolicy(address(0));
        bytes memory data = abi.encodeCall(MockTarget.setX, (2));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = hex"";
        vm.prank(agent);
        vm.expectRevert(EPKernel.BadSignature.selector);
        kernel.execute(policyId, address(target), 0, data, deadline, sig);
    }

    function testSetAgent_zeroAddress_reverts_hitsBranch() public {
        policyId = _createBasicPolicy(address(0));
        vm.prank(owner);
        vm.expectRevert();
        kernel.setAgent(policyId, address(0), false, 0);
    }

    function testSetCall_zeroTarget_reverts_hitsBranch() public {
        policyId = _createBasicPolicy(address(0));
        vm.prank(owner);
        vm.expectRevert();
        kernel.setCall(policyId, address(0), MockTarget.setX.selector, true);
    }

    function testExecute_badSignature_sigLen66_hitsRecoverBranch() public {
        policyId = _createBasicPolicy(address(0));
        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, 1);
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerSk, _digest(policyId, address(target), value, data, kernel.nonces(policyId), deadline));
        bytes memory sig = abi.encodePacked(r, s, v);
        bytes memory bad = new bytes(66);
        for (uint256 i = 0; i < 65; i++) {
            bad[i] = sig[i];
        }
        bad[65] = hex"01";
        vm.prank(agent);
        vm.expectRevert(EPKernel.BadSignature.selector);
        kernel.execute(policyId, address(target), 0, data, deadline, bad);
    }

    function testExecute_badSignature_invalidV_hitsRecoverBranch() public {
        policyId = _createBasicPolicy(address(0));
        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, 1);
        uint256 deadline = block.timestamp + 1;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerSk, _digest(policyId, address(target), value, data, kernel.nonces(policyId), deadline));
        bytes memory sig = abi.encodePacked(r, s, v);
        sig[64] = bytes1(uint8(0));
        vm.prank(agent);
        vm.expectRevert(EPKernel.BadSignature.selector);
        kernel.execute(policyId, address(target), 0, data, deadline, sig);
    }

    function testExecute_badSignature_ecrecoverZero_hitsRecoverBranch() public {
        policyId = _createBasicPolicy(address(0));
        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, 1);
        uint256 deadline = block.timestamp + 1;
        bytes memory sig = new bytes(65);
        sig[64] = bytes1(uint8(27));
        vm.prank(agent);
        vm.expectRevert(EPKernel.BadSignature.selector);
        kernel.execute(policyId, address(target), 0, data, deadline, sig);
    }

    function testExecute_badSignature_sTooHigh_hitsRecoverBranch() public {
        policyId = _createBasicPolicy(address(0));
        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, 1);
        uint256 deadline = block.timestamp + 1;
        bytes memory sig = new bytes(65);
        assembly {
            mstore(add(sig, 0x20), 1)
            mstore(add(sig, 0x40), not(0))
        }
        sig[64] = bytes1(uint8(27));
        vm.prank(agent);
        vm.expectRevert(EPKernel.BadSignature.selector);
        kernel.execute(policyId, address(target), 0, data, deadline, sig);
    }

    function testDomainSeparator_changesWhenChainIdChanges_hitsLine() public {
        policyId = _createBasicPolicy(address(0));
        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, 1);
        bytes32 dataHash = keccak256(data);
        bytes32 h1 = kernel.getTypedDataHash(policyId, address(target), 0, dataHash, 0, block.timestamp + 1);
        vm.chainId(block.chainid + 1);
        bytes32 h2 = kernel.getTypedDataHash(policyId, address(target), 0, dataHash, 0, block.timestamp + 1);
        assertTrue(h1 != h2);
    }
}

contract EPKernelBranchCoverageMoreTest is Test {
    EPKernel internal kernel;
    MockTarget internal target;
    OkValidator internal ok;
    uint256 internal ownerPk = 0xA11CE;
    address internal owner;
    address internal agent = address(0xB0B);
    uint256 internal policyId;
    uint256 internal value = 1;

    function setUp() public {
        owner = vm.addr(ownerPk);
        kernel = new EPKernel();
        target = new MockTarget();
        ok = new OkValidator();
        vm.prank(owner);
        policyId = kernel.createPolicy(0, type(uint96).max, address(ok));
        vm.prank(owner);
        kernel.setAgent(policyId, agent, true, uint40(block.timestamp + 365 days));
        vm.prank(owner);
        kernel.setCall(policyId, address(target), MockTarget.setX.selector, true);
    }

    function _digest(uint256 pid, address tgt, uint256 val, bytes memory data, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return kernel.getTypedDataHash(pid, tgt, val, keccak256(data), nonce, deadline);
    }

    function _sig(bytes32 dig) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, dig);
        return abi.encodePacked(r, s, v);
    }

    function test_onlyPolicyOwner_notOwner_hitsRequireBranch_line113() public {
        vm.prank(agent);
        vm.expectRevert(EPKernel.NotPolicyOwner.selector);
        kernel.setPolicyActive(policyId, false);
    }

    function test_setAgent_success_hitsRequireTrueBranch_line138() public {
        vm.prank(owner);
        kernel.setAgent(policyId, address(0xCAFE), false, 0);
    }

    function test_setCall_success_hitsRequireTrueBranch_line147() public {
        vm.prank(owner);
        kernel.setCall(policyId, address(0xBEEF), bytes4(0x12345678), false);
    }

    function test_execute_deadlineEqualsNow_hitsExpiredLE_line180() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, uint256(1));
        uint256 deadline = block.timestamp; // <= now
        uint256 nonce = kernel.nonces(policyId);
        bytes memory sig = _sig(_digest(policyId, address(target), 0, data, nonce, deadline));
        vm.prank(agent);
        vm.expectRevert(bytes4(keccak256("Expired()")));
        kernel.execute(policyId, address(target), 0, data, deadline, sig);
    }

    function test_execute_policyTTLAlreadyPast_hitsEffectiveExpiry_line185() public {
        vm.prank(owner);
        uint256 pid = kernel.createPolicy(2, 0, address(0)); // validUntil=2
        vm.prank(owner);
        kernel.setAgent(pid, agent, true, 0);
        vm.prank(owner);
        kernel.setCall(pid, address(target), MockTarget.setX.selector, true);
        vm.warp(3); // policy expired
        bytes memory data = abi.encodeCall(MockTarget.setX, (2));
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerPk, _digest(pid, address(target), 0, data, kernel.nonces(pid), deadline));
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.prank(agent);
        vm.expectRevert();
        kernel.execute(pid, address(target), 0, data, deadline, sig);
    }

    function test_execute_agentExpired_hitsLine190() public {
        vm.prank(owner);
        kernel.setAgent(policyId, agent, true, 2); // agent validUntil=2
        vm.warp(3); // agent expired
        bytes memory data = abi.encodeCall(MockTarget.setX, (3));
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerPk, _digest(policyId, address(target), 0, data, kernel.nonces(policyId), deadline));
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.prank(agent);
        vm.expectRevert();
        kernel.execute(policyId, address(target), 0, data, deadline, sig);
    }

    function test_execute_valueTooHigh_hitsLine199() public {
        vm.prank(owner);
        uint256 pid = kernel.createPolicy(0, 1, address(0));
        vm.prank(owner);
        kernel.setAgent(pid, agent, true, 0);
        vm.prank(owner);
        kernel.setCall(pid, address(target), MockTarget.setX.selector, true);
        bytes memory data = abi.encodeCall(MockTarget.setX, (4));
        uint256 deadline = block.timestamp + 100;
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerPk, _digest(pid, address(target), 2, data, kernel.nonces(pid), deadline));
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.prank(agent);
        vm.expectRevert();
        kernel.execute(pid, address(target), 2, data, deadline, sig);
    }

    function test_recover_vBelow27_path_hitsLine295_and_executes() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, uint256(6));
        uint256 deadline = block.timestamp + 100;
        uint256 nonce = kernel.nonces(policyId);
        bytes32 dig = _digest(policyId, address(target), 0, data, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, dig);
        require(v == 27 || v == 28, "unexpected v from vm.sign");
        uint8 vLow = v - 27; // 0/1
        bytes memory sig = abi.encodePacked(r, s, vLow);
        vm.prank(agent);
        kernel.execute(policyId, address(target), 0, data, deadline, sig);
        assertEq(target.x(), 6);
    }

    function test_recover_invalidV_afterAdjust_hitsLine296() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, uint256(7));
        uint256 deadline = block.timestamp + 100;
        uint256 nonce = kernel.nonces(policyId);
        bytes32 dig = _digest(policyId, address(target), 0, data, nonce, deadline);
        (, bytes32 r, bytes32 s) = vm.sign(ownerPk, dig);
        bytes memory sig = abi.encodePacked(r, s, uint8(2)); // -> 29 after adjust
        vm.prank(agent);
        vm.expectRevert(bytes4(keccak256("BadSignature()")));
        kernel.execute(policyId, address(target), 0, data, deadline, sig);
    }

    function test_recover_signerZero_hitsLine304() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, uint256(8));
        uint256 deadline = block.timestamp + 100;
        bytes memory sig = abi.encodePacked(bytes32(0), bytes32(0), uint8(27));
        vm.prank(agent);
        vm.expectRevert(bytes4(keccak256("BadSignature()")));
        kernel.execute(policyId, address(target), 0, data, deadline, sig);
    }
}

contract EPKernelMissingBranchesTest is Test {
    EPKernel internal kernel;
    MockTarget internal target;
    OkValidator internal ok;
    uint256 internal ownerPk = 0xA11CE;
    address internal owner;
    address internal agent = address(0xB0B);
    uint256 internal policyId;

    function setUp() public {
        owner = vm.addr(ownerPk);
        kernel = new EPKernel();
        target = new MockTarget();
        ok = new OkValidator();
        vm.prank(owner);
        policyId = kernel.createPolicy(0, type(uint96).max, address(ok));
        vm.prank(owner);
        kernel.setAgent(policyId, agent, true, uint40(block.timestamp + 365 days));
        vm.prank(owner);
        kernel.setCall(policyId, address(target), MockTarget.setX.selector, true);
    }

    function _digest(uint256 pid, address tgt, uint256 val, bytes memory data, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return kernel.getTypedDataHash(pid, tgt, val, keccak256(data), nonce, deadline);
    }

    function _sig(bytes32 dig) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, dig);
        return abi.encodePacked(r, s, v);
    }

    // line 180: deadline == 0 -> DeadlineRequired()
    function test_execute_deadlineZero_hitsDeadlineRequired_line180() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, uint256(11));
        uint256 nonce = kernel.nonces(policyId);
        bytes memory sig = _sig(_digest(policyId, address(target), 0, data, nonce, 0));
        vm.prank(agent);
        vm.expectRevert(bytes4(keccak256("DeadlineRequired()")));
        kernel.execute(policyId, address(target), 0, data, 0, sig);
    }

    // line 190: !ap.allowed -> AgentNotAllowed()
    function test_execute_agentNotAllowed_hitsLine190() public {
        vm.prank(owner);
        kernel.setAgent(policyId, agent, false, 0);
        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, uint256(12));
        uint256 deadline = block.timestamp + 100;
        uint256 nonce = kernel.nonces(policyId);
        bytes memory sig = _sig(_digest(policyId, address(target), 0, data, nonce, deadline));
        vm.prank(agent);
        vm.expectRevert(bytes4(keccak256("AgentNotAllowed()")));
        kernel.execute(policyId, address(target), 0, data, deadline, sig);
    }

    // line 200: msg.value != value -> MsgValueMismatch()
    function test_execute_msgValueMismatch_hitsLine200() public {
        vm.prank(owner);
        uint256 pid = kernel.createPolicy(0, type(uint96).max, address(ok));
        vm.prank(owner);
        kernel.setAgent(pid, agent, true, 0);
        vm.prank(owner);
        kernel.setCall(pid, address(target), MockTarget.setX.selector, true);
        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, uint256(13));
        uint256 deadline = block.timestamp + 100;
        uint256 nonce = kernel.nonces(pid);
        bytes memory sig = _sig(_digest(pid, address(target), 1, data, nonce, deadline));
        vm.prank(agent);
        vm.expectRevert(bytes4(keccak256("MsgValueMismatch()")));
        kernel.execute(pid, address(target), 1, data, deadline, sig);
    }

    function test_finalpush_success_hits_238_and_recover_290_291_292_305() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, uint256(777));
        uint256 nonce = kernel.nonces(policyId);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 dig = _digest(policyId, address(target), 0, data, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, dig);
        if (v >= 27) v = v - 27;
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.prank(agent);
        bytes memory ret = kernel.execute(policyId, address(target), 0, data, deadline, sig);
        assertEq(target.x(), 777, "target.x not updated");
        assertEq(ret.length, 0, "setX should return empty bytes");
    }

    function test_finalpush_revertBubble_hits_233() public {
        bytes4 badSel = bytes4(keccak256("noSuchFunction()"));
        bytes memory data = abi.encodeWithSelector(badSel);
        vm.prank(owner);
        kernel.setCall(policyId, address(target), badSel, true);

        uint256 nonce = kernel.nonces(policyId);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 dig = _digest(policyId, address(target), 0, data, nonce, deadline);
        bytes memory sig = _sig(dig);

        vm.prank(agent);
        vm.expectRevert();
        kernel.execute(policyId, address(target), 0, data, deadline, sig);
    }
}



