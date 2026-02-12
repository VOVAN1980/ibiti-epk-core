// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "./EPKernel.coverage.t.sol";
contract ReverterLocal {
    function willRevert() external pure {
        revert("RV");
    }
}
contract EPKernelCoverageFinalExtraTest is EPKernelCoverageExtraTest {
    function _mkPolicyAndAllowTarget(address tgt, bytes4 sel) internal returns (uint256 pid) {
        vm.prank(owner);
        pid = kernel.createPolicy(uint48(block.timestamp + 1 days), type(uint96).max, address(0));
        vm.prank(owner);
        kernel.setAgent(pid, agent, true, 0);
        vm.prank(owner);
        kernel.setCall(pid, tgt, sel, true);
    }
    // lines 124,128-132
    function test_final_updatePolicy_success_hits_124_132() public {
        uint256 pid = _mkPolicyAndAllowTarget(address(target), MockTarget.setX.selector);
        uint48 newUntil = uint48(block.timestamp + 7 days);
        uint96 newMax = 123456;
        address newValidator = address(0xBEEF);
        vm.prank(owner);
        kernel.updatePolicy(pid, newUntil, newMax, newValidator);
        (address pOwner, bool active, uint48 validUntil, uint96 maxValuePerCall, address validator) = kernel.policies(pid);
        assertEq(pOwner, owner);
        assertTrue(active);
        assertEq(validUntil, newUntil);
        assertEq(maxValuePerCall, newMax);
        assertEq(validator, newValidator);
    }
    // line 224
    function test_final_targetCallRevert_hits_224() public {
        ReverterLocal rr = new ReverterLocal();
        uint256 pid = _mkPolicyAndAllowTarget(address(rr), bytes4(keccak256("willRevert()")));
        bytes memory data = abi.encodeWithSignature("willRevert()");
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCurrentNonce(pid, address(rr), 0, data, deadline);
        vm.prank(agent);
        vm.expectRevert(bytes("RV"));
        kernel.execute(pid, address(rr), 0, data, deadline, sig);
    }
    // line 229
    function test_final_executeReturn_hits_229() public {
        uint256 pid = _mkPolicyAndAllowTarget(address(target), MockTarget.setX.selector);
        bytes memory data = abi.encodeCall(MockTarget.setX, (777));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCurrentNonce(pid, address(target), 0, data, deadline);
        vm.prank(agent);
        bytes memory ret = kernel.execute(pid, address(target), 0, data, deadline, sig);
        assertEq(ret.length, 0);
        assertEq(target.x(), 777);
    }
    // lines 274-276 + 288
    function test_final_recoverSigner_happy_hits_274_276_288() public {
        uint256 pid = _mkPolicyAndAllowTarget(address(target), MockTarget.setX.selector);
        bytes memory data = abi.encodeCall(MockTarget.setX, (888));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCurrentNonce(pid, address(target), 0, data, deadline);
        vm.prank(agent);
        kernel.execute(pid, address(target), 0, data, deadline, sig);
        assertEq(target.x(), 888);
    }
}
contract ReverterRaw {
    fallback() external payable {
        assembly {
            mstore(0x00, 0x08c379a0) // Error(string)
            mstore(0x20, 0x20)
            mstore(0x40, 2)
            mstore(0x60, 0x5256000000000000000000000000000000000000000000000000000000000000) // "RV"
            revert(0x00, 0x80)
        }
    }
}
contract EPKernelCoverageFinalTailTest is EPKernelCoverageExtraTest {
    function _mk() internal returns (uint256 pid) {
        vm.prank(owner);
        pid = kernel.createPolicy(uint48(block.timestamp + 1 days), type(uint96).max, address(0));
        vm.prank(owner);
        kernel.setAgent(pid, agent, true, 0);
    }
    // hits 274/275/276/288 + 229
    function test_tail_success_return_and_recover_lines() public {
        uint256 pid = _mk();
        vm.prank(owner);
        kernel.setCall(pid, address(target), MockTarget.setX.selector, true);
        bytes memory data = abi.encodeCall(MockTarget.setX, (999));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCurrentNonce(pid, address(target), 0, data, deadline);
        vm.prank(agent);
        bytes memory ret = kernel.execute(pid, address(target), 0, data, deadline, sig);
        assertEq(ret.length, 0);
        assertEq(target.x(), 999);
    }
    // hits 224 (revert bubble from target.call)
    function test_tail_target_revert_bubble_line_224() public {
        uint256 pid = _mk();
        ReverterRaw rr = new ReverterRaw();
        bytes4 sel = bytes4(keccak256("nope()"));
        vm.prank(owner);
        kernel.setCall(pid, address(rr), sel, true);
        bytes memory data = abi.encodeWithSelector(sel);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signCurrentNonce(pid, address(rr), 0, data, deadline);
        vm.prank(agent);
        vm.expectRevert(); // raw bubble
        kernel.execute(pid, address(rr), 0, data, deadline, sig);
    }
}