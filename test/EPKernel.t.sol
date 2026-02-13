// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/epk/EPKernel.sol";
import "../contracts/epk/IPolicyValidator.sol";
import "../contracts/validators/CompositeValidator.sol";
import "../contracts/mocks/MockTarget.sol";
import "../contracts/mocks/RevertingValidator.sol";

contract OkValidator is IPolicyValidator {
    function validate(uint256, address, address, address, uint256, bytes calldata) external pure override {
        // always passes
    }
}

contract Reverter {
    function willRevert() external pure {
        revert("RV");
    }
}

contract Returner {
    function get() external pure returns (uint256) {
        return 777;
    }
}

contract EPKernelTest is Test {
    EPKernel kernel;
    MockTarget target;

    uint256 ownerSk;
    address owner;
    address agent;

    function setUp() public {
        kernel = new EPKernel();
        target = new MockTarget();

        ownerSk = 0xA11CE;
        owner = vm.addr(ownerSk);
        agent = vm.addr(0xB0B);
    }

    // Helpers

    function _createBasicPolicy(address validator) internal returns (uint256 pid) {
        vm.startPrank(owner);
        pid = kernel.createPolicy(0, type(uint96).max, validator);
        kernel.setAgent(pid, agent, true, 0);
        kernel.setCall(pid, address(target), MockTarget.setX.selector, true);
        vm.stopPrank();
    }

    function _sign(uint256 pid, address to, uint256 value, bytes memory data, uint256 deadline, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = kernel.getTypedDataHash(pid, to, value, keccak256(data), nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerSk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signCurrentNonce(uint256 pid, address to, uint256 value, bytes memory data, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(pid, to, value, data, deadline, kernel.nonces(pid));
    }

    // Tests

    function testExecute_success() public {
        uint256 pid = _createBasicPolicy(address(0));

        bytes memory data = abi.encodeCall(MockTarget.setX, (123));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCurrentNonce(pid, address(target), 0, data, deadline);

        vm.prank(agent);
        kernel.execute(pid, address(target), 0, data, deadline, sig);

        assertEq(target.x(), 123);
        assertEq(kernel.nonces(pid), 1);
    }

    function testExecute_expired_reverts() public {
        uint256 pid = _createBasicPolicy(address(0));

        bytes memory data = abi.encodeCall(MockTarget.setX, (1));
        uint256 deadline = block.timestamp + 10;
        bytes memory sig = _signCurrentNonce(pid, address(target), 0, data, deadline);

        vm.warp(deadline + 1);

        vm.prank(agent);
        vm.expectRevert(EPKernel.Expired.selector);
        kernel.execute(pid, address(target), 0, data, deadline, sig);
    }

    function testExecute_badSignature_wrongNonce_reverts() public {
        uint256 pid = _createBasicPolicy(address(0));

        bytes memory data = abi.encodeCall(MockTarget.setX, (1));
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _sign(pid, address(target), 0, data, deadline, kernel.nonces(pid) + 1);

        vm.prank(agent);
        vm.expectRevert(EPKernel.BadSignature.selector);
        kernel.execute(pid, address(target), 0, data, deadline, sig);
    }

    function testExecute_agentNotAllowed_reverts() public {
        vm.prank(owner);
        uint256 pid = kernel.createPolicy(0, type(uint96).max, address(0));

        vm.prank(owner);
        kernel.setCall(pid, address(target), MockTarget.setX.selector, true);

        bytes memory data = abi.encodeCall(MockTarget.setX, (1));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCurrentNonce(pid, address(target), 0, data, deadline);

        vm.prank(agent);
        vm.expectRevert(EPKernel.AgentNotAllowed.selector);
        kernel.execute(pid, address(target), 0, data, deadline, sig);
    }

    function testExecute_callNotAllowed_reverts() public {
        uint256 pid = _createBasicPolicy(address(0));

        vm.prank(owner);
        kernel.setCall(pid, address(target), MockTarget.setX.selector, false);

        bytes memory data = abi.encodeCall(MockTarget.setX, (1));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCurrentNonce(pid, address(target), 0, data, deadline);

        vm.prank(agent);
        vm.expectRevert(EPKernel.CallNotAllowed.selector);
        kernel.execute(pid, address(target), 0, data, deadline, sig);
    }

    function testPolicyInactive_reverts() public {
        uint256 pid = _createBasicPolicy(address(0));

        vm.prank(owner);
        kernel.setPolicyActive(pid, false);

        bytes memory data = abi.encodeCall(MockTarget.setX, (1));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCurrentNonce(pid, address(target), 0, data, deadline);

        vm.prank(agent);
        vm.expectRevert(EPKernel.PolicyInactive.selector);
        kernel.execute(pid, address(target), 0, data, deadline, sig);
    }

    function testValidator_revert_bubblesUp() public {
        RevertingValidator revertingValidator = new RevertingValidator();

        uint256 pid = _createBasicPolicy(address(revertingValidator));

        bytes memory data = abi.encodeCall(MockTarget.setX, (1));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCurrentNonce(pid, address(target), 0, data, deadline);

        vm.prank(agent);
        vm.expectRevert(RevertingValidator.ValidatorRejected.selector);
        kernel.execute(pid, address(target), 0, data, deadline, sig);
    }

    function testCompositeValidator_secondFails_reverts() public {
        address[] memory empty = new address[](0);
        CompositeValidator composite = new CompositeValidator(address(kernel), owner, empty);

        OkValidator okValidator = new OkValidator();
        RevertingValidator badValidator = new RevertingValidator();

        address[] memory validators = new address[](2);
        validators[0] = address(okValidator);
        validators[1] = address(badValidator);

        vm.prank(owner);
        composite.setValidators(validators);

        uint256 pid = _createBasicPolicy(address(composite));

        bytes memory data = abi.encodeCall(MockTarget.setX, (1));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCurrentNonce(pid, address(target), 0, data, deadline);

        vm.prank(agent);
        vm.expectRevert(RevertingValidator.ValidatorRejected.selector);
        kernel.execute(pid, address(target), 0, data, deadline, sig);
    }

    function testExecute_replaySignature_revertsOnSecondCall() public {
        uint256 pid = _createBasicPolicy(address(0));

        bytes memory data = abi.encodeCall(MockTarget.setX, (222));
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signCurrentNonce(pid, address(target), 0, data, deadline);

        vm.prank(agent);
        kernel.execute(pid, address(target), 0, data, deadline, sig);
        assertEq(target.x(), 222);

        vm.prank(agent);
        vm.expectRevert(EPKernel.BadSignature.selector);
        kernel.execute(pid, address(target), 0, data, deadline, sig);
    }

    function testSignatureCannotBeReplayedOnDifferentPolicy() public {
        uint256 pid1 = _createBasicPolicy(address(0));
        uint256 pid2 = _createBasicPolicy(address(0));

        bytes memory data = abi.encodeCall(MockTarget.setX, (999));
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig = _signCurrentNonce(pid1, address(target), 0, data, deadline);

        vm.prank(agent);
        kernel.execute(pid1, address(target), 0, data, deadline, sig);
        assertEq(target.x(), 999);

        vm.prank(agent);
        vm.expectRevert(EPKernel.BadSignature.selector);
        kernel.execute(pid2, address(target), 0, data, deadline, sig);
    }

    function testEmergencyNonceBump_onlyOwner_revertsForAgent() public {
        uint256 pid = _createBasicPolicy(address(0));
        uint256 cur = kernel.nonces(pid);

        vm.prank(agent);
        vm.expectRevert(bytes("Not policy owner"));
        kernel.emergencyNonceBump(pid, cur + 1);
    }

    function testExecute_deadlineNowPlusOne_success() public {
        uint256 pid = _createBasicPolicy(address(0));

        bytes memory data = abi.encodeCall(MockTarget.setX, (77));
        uint256 deadline = block.timestamp + 1;
        bytes memory sig = _signCurrentNonce(pid, address(target), 0, data, deadline);

        vm.prank(agent);
        kernel.execute(pid, address(target), 0, data, deadline, sig);

        assertEq(target.x(), 77);
    }

    function testExecute_targetRevert_bubblesRawData() public {
        Reverter rv = new Reverter();

        vm.prank(owner);
        uint256 pid = kernel.createPolicy(0, type(uint96).max, address(0));

        vm.prank(owner);
        kernel.setAgent(pid, agent, true, 0);

        vm.prank(owner);
        kernel.setCall(pid, address(rv), Reverter.willRevert.selector, true);

        bytes memory data = abi.encodeWithSelector(Reverter.willRevert.selector);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCurrentNonce(pid, address(rv), 0, data, deadline);

        vm.prank(agent);
        vm.expectRevert(bytes("RV"));
        kernel.execute(pid, address(rv), 0, data, deadline, sig);
    }

    function testExecute_returnsRawRetdata_onSuccess() public {
        Returner rt = new Returner();

        vm.prank(owner);
        uint256 pid = kernel.createPolicy(0, type(uint96).max, address(0));

        vm.prank(owner);
        kernel.setAgent(pid, agent, true, 0);

        vm.prank(owner);
        kernel.setCall(pid, address(rt), Returner.get.selector, true);

        bytes memory data = abi.encodeWithSelector(Returner.get.selector);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCurrentNonce(pid, address(rt), 0, data, deadline);

        vm.prank(agent);
        bytes memory ret = kernel.execute(pid, address(rt), 0, data, deadline, sig);

        assertEq(abi.decode(ret, (uint256)), 777);
    }
}
