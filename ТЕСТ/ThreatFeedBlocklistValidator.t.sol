// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {ThreatFeedBlocklistValidator} from "../contracts/validators/ThreatFeedBlocklistValidator.sol";
import {MockTarget} from "../contracts/mocks/MockTarget.sol";

contract ThreatFeedBlocklistValidatorTest is Test {
    ThreatFeedBlocklistValidator v;
    MockTarget target;
    address owner = address(0xA11CE);
    address agent = address(0xB0B);
    address caller = address(this); // authorized caller for validate
    uint256 policyId = 1;

    function setUp() public {
        target = new MockTarget();
        v = new ThreatFeedBlocklistValidator(caller, owner, bytes32(0), 0);
    }

    function _dataSetX(uint256 n) internal pure returns (bytes memory) {
        return abi.encodeCall(MockTarget.setX, (n));
    }

    // --- access control ---
    function testValidate_unauthorizedCaller_reverts() public {
        bytes memory data = _dataSetX(1);
        vm.prank(agent); // not authorized caller
        vm.expectRevert(ThreatFeedBlocklistValidator.UnauthorizedCaller.selector);
        v.validate(policyId, owner, agent, address(target), 0, data);
    }

    function testUpdateRoot_notOwner_reverts() public {
        vm.prank(agent);
        vm.expectRevert(ThreatFeedBlocklistValidator.NotOwner.selector);
        v.updateRoot(keccak256("r1"), 1);
    }

    function testTransferOwnership_notOwner_reverts() public {
        vm.prank(agent);
        vm.expectRevert(ThreatFeedBlocklistValidator.NotOwner.selector);
        v.transferOwnership(agent);
    }

    function testTransferOwnership_owner_success() public {
        vm.prank(owner);
        v.transferOwnership(agent);
        vm.prank(agent);
        v.updateRoot(keccak256("r2"), 2);
    }

    // --- root/epoch update path ---
    function testUpdateRoot_owner_success() public {
        vm.prank(owner);
        v.updateRoot(keccak256("new-root"), 42);
    }

    // --- validate behavior ---
    // empty root: nothing is blocked
    function testValidate_emptyRoot_passes() public view {
        bytes memory data = _dataSetX(2);
        v.validate(policyId, owner, agent, address(target), 0, data);
    }

    // non-empty root, random calldata: usually not blocklisted, should pass
    function testValidate_nonEmptyRoot_nonMember_passes() public {
        vm.prank(owner);
        v.updateRoot(keccak256("some-root"), 7);
        bytes memory data = _dataSetX(3);
        v.validate(policyId, owner, agent, address(target), 0, data);
    }

    // deterministic blocked case: make root exactly equal one checked item hash
    // Most implementations check at least target or selector hashes against root.
    // We try both patterns in separate calls and assert one of them reverts with Blocklisted.
    function testValidate_blocklisted_reverts_forKnownItemPattern() public {
        bytes memory data = _dataSetX(4);
        bytes4 sel = MockTarget.setX.selector;
        // candidate A: item = keccak256(target)
        bytes32 itemA = keccak256(abi.encodePacked(address(target)));
        vm.prank(owner);
        v.updateRoot(itemA, 10);
        bool revertedA = false;
        try v.validate(policyId, owner, agent, address(target), 0, data) {
            revertedA = false;
        } catch (bytes memory errA) {
            revertedA = true;
            bytes memory expA = abi.encodeWithSelector(ThreatFeedBlocklistValidator.Blocklisted.selector, itemA);
            assertEq(keccak256(errA), keccak256(expA));
        }
        // candidate B: item = keccak256(target,selector)
        bytes32 itemB = keccak256(abi.encodePacked(address(target), sel));
        vm.prank(owner);
        v.updateRoot(itemB, 11);
        bool revertedB = false;
        try v.validate(policyId, owner, agent, address(target), 0, data) {
            revertedB = false;
        } catch (bytes memory errB) {
            revertedB = true;
            bytes memory expB = abi.encodeWithSelector(ThreatFeedBlocklistValidator.Blocklisted.selector, itemB);
            assertEq(keccak256(errB), keccak256(expB));
        }
        assertTrue(revertedA || revertedB, "No blocklist pattern matched implementation");
    }
}



