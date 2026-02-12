// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CompositeValidator} from "../contracts/validators/CompositeValidator.sol";
import {IPolicyValidator} from "../contracts/epk/IPolicyValidator.sol";
import {RevertingValidator} from "../contracts/mocks/RevertingValidator.sol";

contract PassValidator is IPolicyValidator {
    function validate(uint256, address, address, address, uint256, bytes calldata) external pure override {}
}

contract CompositeValidatorTest is Test {
    CompositeValidator comp;

    address owner = address(0xA11CE);
    address notOwner = address(0xB0B);
    address kernel = address(this); // authorized caller for validate

    uint256 policyId = 1;
    address policyOwner = address(0xCAFE);
    address agent = address(0xBEEF);
    address target = address(0x1234);

    PassValidator passV;
    RevertingValidator revertV;

    function setUp() public {
        passV = new PassValidator();
        revertV = new RevertingValidator();

        address[] memory initVals = new address[](1);
        initVals[0] = address(passV);

        comp = new CompositeValidator(kernel, owner, initVals);
    }

    function testValidate_unauthorizedCaller_reverts() public {
        vm.prank(notOwner);
        vm.expectRevert(CompositeValidator.UnauthorizedCaller.selector);
        comp.validate(policyId, policyOwner, agent, target, 0, hex"12345678");
    }

    function testSetValidators_notOwner_reverts() public {
        address[] memory vals = new address[](1);
        vals[0] = address(passV);

        vm.prank(notOwner);
        vm.expectRevert();
        comp.setValidators(vals);
    }

    function testSetValidators_zeroAddress_reverts() public {
        address[] memory vals = new address[](1);
        vals[0] = address(0);

        vm.prank(owner);
        vm.expectRevert(CompositeValidator.ZeroValidator.selector);
        comp.setValidators(vals);
    }

    function testSetValidators_owner_success_updatesLength() public {
        address[] memory vals = new address[](2);
        vals[0] = address(passV);
        vals[1] = address(passV);

        vm.prank(owner);
        comp.setValidators(vals);

        assertEq(comp.validatorsLength(), 2);
    }

    function testValidate_singlePass_passes() public {
        comp.validate(policyId, policyOwner, agent, target, 0, hex"12345678");
    }

    function testValidate_secondReverts_bubbles() public {
        address[] memory vals = new address[](2);
        vals[0] = address(passV);
        vals[1] = address(revertV);

        vm.prank(owner);
        comp.setValidators(vals);

        vm.expectRevert(RevertingValidator.ValidatorRejected.selector);
        comp.validate(policyId, policyOwner, agent, target, 0, hex"12345678");
    }

    function testValidate_emptyList_passes() public {
        address[] memory vals = new address[](0);

        vm.prank(owner);
        comp.setValidators(vals);

        comp.validate(policyId, policyOwner, agent, target, 0, hex"12345678");
    }

    function testTransferOwnership_notOwner_reverts() public {
        vm.prank(notOwner);
        vm.expectRevert();
        comp.transferOwnership(notOwner);
    }

    function testTransferOwnership_owner_success() public {
        vm.prank(owner);
        comp.transferOwnership(notOwner);

        address[] memory vals = new address[](1);
        vals[0] = address(passV);

        vm.prank(notOwner);
        comp.setValidators(vals);

        assertEq(comp.validatorsLength(), 1);
    }
}
