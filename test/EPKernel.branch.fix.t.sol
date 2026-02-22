 // SPDX-License-Identifier: MIT
 pragma solidity ^0.8.24;
 import "forge-std/Test.sol";
 import {EPKernel} from "../contracts/epk/EPKernel.sol";
 import {MockTarget} from "../contracts/mocks/MockTarget.sol";
 contract EPKernelBranchFixTest is Test {
     EPKernel internal kernel;
     MockTarget internal mock;
     address internal OWNER    = address(0xA11CE);
     address internal ATTACKER = address(0xB0B);
     address internal AGENT    = address(0xCAFE);
     function setUp() public {
         kernel = new EPKernel();
         mock = new MockTarget();
     }
     function _createPolicyAs(address who) internal returns (uint256 id) {
         vm.prank(who);
         kernel.createPolicy(
             uint48(block.timestamp + 1 days),
             uint96(1 ether),
             address(0)
         );
         id = kernel.nextPolicyId() - 1;
     }
     // line 114 pass
     function test_branch114_onlyPolicyOwner_pass() public {
         uint256 id = _createPolicyAs(OWNER);
         vm.prank(OWNER);
         kernel.setPolicyActive(id, false);
     }
     // line 114 fail
     function test_branch114_onlyPolicyOwner_fail() public {
         uint256 id = _createPolicyAs(OWNER);
         vm.prank(ATTACKER);
         vm.expectRevert(EPKernel.NotPolicyOwner.selector);
         kernel.setPolicyActive(id, false);
     }
     // line 139 pass
     function test_branch139_setAgent_pass() public {
         uint256 id = _createPolicyAs(OWNER);
         vm.prank(OWNER);
         kernel.setAgent(id, AGENT, true, uint40(block.timestamp + 1 days));
     }
     // line 139 fail
     function test_branch139_setAgent_fail_zeroAgent() public {
         uint256 id = _createPolicyAs(OWNER);
         vm.prank(OWNER);
         vm.expectRevert(EPKernel.ZeroAgent.selector);
         kernel.setAgent(id, address(0), true, 0);
     }
     // line 148 pass
     function test_branch148_setCall_pass() public {
         uint256 id = _createPolicyAs(OWNER);
         vm.prank(OWNER);
         kernel.setCall(id, address(mock), bytes4(keccak256("setX(uint256)")), true);
     }
     // line 148 fail
     function test_branch148_setCall_fail_zeroTarget() public {
         uint256 id = _createPolicyAs(OWNER);
         vm.prank(OWNER);
         vm.expectRevert(EPKernel.ZeroTarget.selector);
         kernel.setCall(id, address(0), bytes4(0x12345678), true);
     }
 }



