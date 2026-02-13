// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {TargetSelectorGuard} from "../contracts/validators/TargetSelectorGuard.sol";
import {MockTarget} from "../contracts/mocks/MockTarget.sol";

contract TargetSelectorGuardTest is Test {
    TargetSelectorGuard guard;
    MockTarget target;
    address owner = address(0xA11CE);
    address agent = address(0xB0B);
    address caller = address(this); // authorized caller
    uint256 policyId = 1;

    function setUp() public {
        target = new MockTarget();
        guard = new TargetSelectorGuard(caller, owner);
    }

    function _dataSetX(uint256 v) internal pure returns (bytes memory) {
        return abi.encodeCall(MockTarget.setX, (v));
    }

    function testValidate_unauthorizedCaller_reverts() public {
        bytes memory data = _dataSetX(1);
        vm.prank(agent);
        vm.expectRevert(TargetSelectorGuard.UnauthorizedCaller.selector);
        guard.validate(policyId, owner, agent, address(target), 0, data);
    }

    function testValidate_blockedSelector_reverts() public {
        vm.prank(owner);
        guard.setBlockedSelector(MockTarget.setX.selector, true);
        bytes memory data = _dataSetX(2);
        vm.expectRevert(abi.encodeWithSelector(TargetSelectorGuard.BlockedSelector.selector, MockTarget.setX.selector));
        guard.validate(policyId, owner, agent, address(target), 0, data);
    }

    function testValidate_blockedCallKey_reverts() public {
        vm.prank(owner);
        guard.setBlockedCallKey(policyId, address(target), MockTarget.setX.selector, true);
        bytes memory data = _dataSetX(3);
        bytes32 callKey = keccak256(abi.encodePacked(address(target), MockTarget.setX.selector));
        vm.expectRevert(abi.encodeWithSelector(TargetSelectorGuard.BlockedCall.selector, policyId, callKey));
        guard.validate(policyId, owner, agent, address(target), 0, data);
    }

    function testValidate_notBlocked_passes() public view {
        bytes memory data = _dataSetX(4);
        guard.validate(policyId, owner, agent, address(target), 0, data);
    }

    // onlyOwner: setBlockedSelector
    function testSetBlockedSelector_notOwner_reverts() public {
        vm.prank(agent);
        vm.expectRevert(TargetSelectorGuard.NotOwner.selector);
        guard.setBlockedSelector(MockTarget.setX.selector, true);
    }

    // onlyOwner: setBlockedCallKey
    function testSetBlockedCallKey_notOwner_reverts() public {
        vm.prank(agent);
        vm.expectRevert(TargetSelectorGuard.NotOwner.selector);
        guard.setBlockedCallKey(policyId, address(target), MockTarget.setX.selector, true);
    }

    // onlyOwner: transferOwnership
    function testTransferOwnership_notOwner_reverts() public {
        vm.prank(agent);
        vm.expectRevert(TargetSelectorGuard.NotOwner.selector);
        guard.transferOwnership(agent);
    }

    function testTransferOwnership_owner_success() public {
        vm.prank(owner);
        guard.transferOwnership(agent);
        vm.prank(agent);
        guard.setBlockedSelector(MockTarget.setX.selector, true);
    }
}
