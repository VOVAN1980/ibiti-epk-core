// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {EPKernel} from "../contracts/epk/EPKernel.sol";
import {CompositeValidator} from "../contracts/validators/CompositeValidator.sol";
import {ThreatFeedBlocklistValidator} from "../contracts/validators/ThreatFeedBlocklistValidator.sol";
import {TargetSelectorGuard} from "../contracts/validators/TargetSelectorGuard.sol";
import {SpendLimitValidator} from "../contracts/validators/SpendLimitValidator.sol";

contract CoverageBranchesExactTest is Test {
    address constant OWNER  = address(0xA11CE);
    address constant AGENT  = address(0xB0B);
    address constant OTHER  = address(0xC0DE);

    // ──────────────────────────────────────────────────────────────
    // EPKernel — линии 114, 139, 148 (modifiers и require)
    // ──────────────────────────────────────────────────────────────

    function test_epk_line114_onlyPolicyOwner_revertBranch() external {
        EPKernel k = new EPKernel();

        vm.prank(OWNER);
        uint256 id = k.createPolicy(
            uint48(block.timestamp + 1 days),
            uint96(1 ether),
            address(0)
        );

        vm.prank(OTHER);
        vm.expectRevert(bytes("Not policy owner"));
        k.setPolicyActive(id, false);
    }

    function test_epk_line114_onlyPolicyOwner_passBranch() external {
        EPKernel k = new EPKernel();

        vm.prank(OWNER);
        uint256 id = k.createPolicy(
            uint48(block.timestamp + 1 days),
            uint96(1 ether),
            address(0)
        );

        vm.prank(OWNER);
        k.setPolicyActive(id, false);
    }

    function test_epk_line139_zeroAgent_revertBranch() external {
        EPKernel k = new EPKernel();

        vm.prank(OWNER);
        uint256 id = k.createPolicy(
            uint48(block.timestamp + 1 days),
            uint96(1 ether),
            address(0)
        );

        vm.prank(OWNER);
        vm.expectRevert(bytes("Zero agent"));
        k.setAgent(id, address(0), true, 0);
    }

    function test_epk_line139_nonZeroAgent_passBranch() external {
        EPKernel k = new EPKernel();

        vm.prank(OWNER);
        uint256 id = k.createPolicy(
            uint48(block.timestamp + 1 days),
            uint96(1 ether),
            address(0)
        );

        vm.prank(OWNER);
        k.setAgent(id, AGENT, true, 0);
    }

    function test_epk_line148_zeroTarget_revertBranch() external {
        EPKernel k = new EPKernel();

        vm.prank(OWNER);
        uint256 id = k.createPolicy(
            uint48(block.timestamp + 1 days),
            uint96(1 ether),
            address(0)
        );

        vm.prank(OWNER);
        vm.expectRevert(bytes("Zero target"));
        k.setCall(id, address(0), bytes4(keccak256("foo()")), true);
    }

    function test_epk_line148_nonZeroTarget_passBranch() external {
        EPKernel k = new EPKernel();

        vm.prank(OWNER);
        uint256 id = k.createPolicy(
            uint48(block.timestamp + 1 days),
            uint96(1 ether),
            address(0)
        );

        vm.prank(OWNER);
        k.setCall(id, address(0x1234), bytes4(keccak256("foo()")), true);
    }

    // ──────────────────────────────────────────────────────────────
    // CompositeValidator (15, 44, 26)
    // ──────────────────────────────────────────────────────────────

    function test_cv_line15_ctor_zeroOwner_revert() external {
        address[] memory vals = new address[](0);
        vm.expectRevert(bytes("zero owner"));
        new CompositeValidator(address(0x1234), address(0), vals);
    }

    function test_cv_line44_ctor_zeroKernel_revert() external {
        address[] memory vals = new address[](0);
        vm.expectRevert(bytes("zero kernel"));
        new CompositeValidator(address(0), OWNER, vals);
    }

    function test_cv_line26_transferOwnership_zeroOwner_revert() external {
        address[] memory vals = new address[](0);
        CompositeValidator cv = new CompositeValidator(address(0x1234), OWNER, vals);

        vm.prank(OWNER);
        vm.expectRevert(bytes("zero owner"));
        cv.transferOwnership(address(0));
    }

    // ──────────────────────────────────────────────────────────────
    // ThreatFeedBlocklistValidator (21, 22, 38)
    // ──────────────────────────────────────────────────────────────

    function test_tf_line21_ctor_zeroCaller_revert() external {
        vm.expectRevert(bytes("zero caller"));
        new ThreatFeedBlocklistValidator(address(0), OWNER, bytes32(0), 1);
    }

    function test_tf_line22_ctor_zeroOwner_revert() external {
        vm.expectRevert(bytes("zero owner"));
        new ThreatFeedBlocklistValidator(AGENT, address(0), bytes32(0), 1);
    }

    function test_tf_line38_transferOwnership_zeroOwner_revert() external {
        ThreatFeedBlocklistValidator tf = new ThreatFeedBlocklistValidator(AGENT, OWNER, bytes32(0), 1);

        vm.prank(OWNER);
        vm.expectRevert(bytes("zero owner"));
        tf.transferOwnership(address(0));
    }

    // ──────────────────────────────────────────────────────────────
    // TargetSelectorGuard (21, 22, 39)
    // ──────────────────────────────────────────────────────────────

    function test_tsg_line21_ctor_zeroCaller_revert() external {
        vm.expectRevert(bytes("zero caller"));
        new TargetSelectorGuard(address(0), OWNER);
    }

    function test_tsg_line22_ctor_zeroOwner_revert() external {
        vm.expectRevert(bytes("zero owner"));
        new TargetSelectorGuard(AGENT, address(0));
    }

    function test_tsg_line39_transferOwnership_zeroOwner_revert() external {
        TargetSelectorGuard g = new TargetSelectorGuard(AGENT, OWNER);

        vm.prank(OWNER);
        vm.expectRevert(bytes("zero owner"));
        g.transferOwnership(address(0));
    }

    // ──────────────────────────────────────────────────────────────
    // SpendLimitValidator (41, 42, 54, 67, 127)
    // ──────────────────────────────────────────────────────────────

    function test_slv_line41_ctor_zeroCaller_revert() external {
        vm.expectRevert(bytes("zero caller"));
        new SpendLimitValidator(address(0), OWNER);
    }

    function test_slv_line42_ctor_zeroOwner_revert() external {
        vm.expectRevert(bytes("zero owner"));
        new SpendLimitValidator(AGENT, address(0));
    }

    function test_slv_line54_transferOwnership_zeroOwner_revert() external {
        SpendLimitValidator slv = new SpendLimitValidator(AGENT, OWNER);

        vm.prank(OWNER);
        vm.expectRevert(bytes("zero owner"));
        slv.transferOwnership(address(0));
    }

    function test_slv_line67_setLimits_windowZero_revert() external {
        SpendLimitValidator slv = new SpendLimitValidator(AGENT, OWNER);

        vm.prank(OWNER);
        vm.expectRevert(bytes("window=0"));
        slv.setLimits(1, address(0), 1, 1, 0, true);
    }

    function test_slv_line127_badCalldata_revert() external {
        SpendLimitValidator slv = new SpendLimitValidator(address(this), OWNER);

        // transfer(address,uint256) с обрезанным аргументом (первые 4 байта + 1 байт)
        bytes memory bad = abi.encodePacked(bytes4(0xa9059cbb), bytes1(0x01));

        vm.expectRevert(bytes("bad calldata"));
        slv.validate(1, OWNER, OWNER, address(0x1234), 0, bad);
    }
}