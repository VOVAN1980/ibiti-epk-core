// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "../contracts/epk/EPKernel.sol";
import "../contracts/validators/SpendLimitValidator.sol";
import "../contracts/mocks/MockTarget.sol";

contract SpendLimitValidatorTest is Test {
    EPKernel kernel;
    SpendLimitValidator validator;
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
        validator = new SpendLimitValidator(address(kernel), owner);
    }

    function _sign(uint256 pid, address tgt, uint256 value, bytes memory data, uint256 deadline, uint256 nonce)
        internal
        view
        returns (bytes memory sig)
    {
        bytes32 digest = kernel.getTypedDataHash(pid, tgt, value, keccak256(data), nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerSk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _policyWithValidator() internal returns (uint256 pid) {
        vm.prank(owner);
        pid = kernel.createPolicy(0, type(uint48).max, address(validator));
        vm.prank(owner);
        kernel.setAgent(pid, agent, true, 0);
        vm.prank(owner);
        kernel.setCall(pid, address(target), MockTarget.setX.selector, true);
        vm.prank(owner);
        validator.setLimits(pid, address(0), uint128(1 ether), uint32(2_000_000_000), uint32(1 days), true);
    }

    function testSpendLimit_perTx_native() public {
        uint256 pid = _policyWithValidator();
        vm.prank(owner);
        validator.setLimits(pid, address(0), uint128(1000), uint32(1_000_000_000), uint32(1 days), true);
        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, 1);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = kernel.nonces(pid);
        bytes memory sig = _sign(pid, address(target), 1001, data, deadline, nonce);
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        vm.expectRevert(); // PerTxExceeded(...)
        kernel.execute{value: 1001}(pid, address(target), 1001, data, deadline, sig);
    }

    function testSpendLimit_rollingWindow_native() public {
        uint256 pid = _policyWithValidator();
        vm.prank(owner);
        validator.setLimits(pid, address(0), uint128(2000), uint32(2000), uint32(1 days), true);
        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, 1);
        vm.deal(agent, 1 ether);
        // 1) 1000 ok
        uint256 d1 = block.timestamp + 1 hours;
        uint256 n1 = kernel.nonces(pid);
        bytes memory s1 = _sign(pid, address(target), 1000, data, d1, n1);
        vm.prank(agent);
        kernel.execute{value: 1000}(pid, address(target), 1000, data, d1, s1);
        uint256 d2 = block.timestamp + 1 hours;
        uint256 n2 = kernel.nonces(pid);
        bytes memory s2 = _sign(pid, address(target), 1000, data, d2, n2);
        vm.prank(agent);
        kernel.execute{value: 1000}(pid, address(target), 1000, data, d2, s2);
        uint256 d3 = block.timestamp + 1 hours;
        uint256 n3 = kernel.nonces(pid);
        bytes memory s3 = _sign(pid, address(target), 1, data, d3, n3);
        vm.prank(agent);
        vm.expectRevert();
        kernel.execute{value: 1}(pid, address(target), 1, data, d3, s3);
    }
}

// ---- EXTRA COVERAGE TESTS ----
contract SpendLimitValidatorExtraTest is SpendLimitValidatorTest {
    function testSetLimits_notOwner_reverts() public {
        uint256 pid = _policyWithValidator();
        vm.prank(agent);
        vm.expectRevert(SpendLimitValidator.NotOwner.selector);
        validator.setLimits(pid, address(0), uint128(1), uint128(1), uint32(1 days), true);
    }

    function testTransferOwnership_notOwner_reverts() public {
        vm.prank(agent);
        vm.expectRevert(SpendLimitValidator.NotOwner.selector);
        validator.transferOwnership(agent);
    }

    function testTransferOwnership_zeroOwner_reverts() public {
        vm.prank(owner);
        vm.expectRevert(bytes("zero owner"));
        validator.transferOwnership(address(0));
    }

    function testTransferOwnership_success() public {
        uint256 pid = _policyWithValidator();
        address newOwner = address(0xD00D);
        vm.prank(owner);
        validator.transferOwnership(newOwner);
        vm.prank(owner);
        vm.expectRevert(SpendLimitValidator.NotOwner.selector);
        validator.setLimits(pid, address(0), uint128(1), uint128(1), uint32(1 days), true);
        vm.prank(newOwner);
        validator.setLimits(pid, address(0), uint128(1000), uint128(2000), uint32(1 days), true);
    }

    function testSetLimits_windowZero_reverts() public {
        uint256 pid = _policyWithValidator();
        vm.prank(owner);
        vm.expectRevert(bytes("window=0"));
        validator.setLimits(pid, address(0), uint128(1), uint128(1), uint32(0), true);
    }

    function testValidate_unauthorizedCaller_reverts() public {
        vm.prank(agent);
        vm.expectRevert(SpendLimitValidator.UnauthorizedCaller.selector);
        validator.validate(1, owner, agent, address(target), 0, hex"");
    }

    function testValidate_dataTooShort_returns_noRevert() public {
        uint256 pid = _policyWithValidator();
        vm.prank(address(kernel));
        validator.validate(pid, owner, agent, address(target), 0, hex"01");
    }

    function testValidate_limitDisabled_reverts_onNativeValue() public {
        uint256 pid = _policyWithValidator();
        vm.prank(owner);
        validator.setLimits(pid, address(0), uint128(1000), uint128(1000), uint32(1 days), false);
        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, 1);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = kernel.nonces(pid);
        bytes memory sig = _sign(pid, address(target), 1, data, deadline, nonce);
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SpendLimitValidator.LimitDisabled.selector, address(0)));
        kernel.execute{value: 1}(pid, address(target), 1, data, deadline, sig);
    }

    function testValidate_perWindowResetAfterWindow_passes() public {
        uint256 pid = _policyWithValidator();
        vm.prank(owner);
        validator.setLimits(pid, address(0), uint128(2000), uint128(2000), uint32(1 days), true);
        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, 1);
        vm.deal(agent, 2 ether);
        uint256 d1 = block.timestamp + 1 hours;
        uint256 n1 = kernel.nonces(pid);
        bytes memory s1 = _sign(pid, address(target), 2000, data, d1, n1);
        vm.prank(agent);
        kernel.execute{value: 2000}(pid, address(target), 2000, data, d1, s1);
        uint256 d2 = block.timestamp + 1 hours;
        uint256 n2 = kernel.nonces(pid);
        bytes memory s2 = _sign(pid, address(target), 1, data, d2, n2);
        vm.prank(agent);
        vm.expectRevert();
        kernel.execute{value: 1}(pid, address(target), 1, data, d2, s2);
        vm.warp(block.timestamp + 1 days + 1);
        uint256 d3 = block.timestamp + 1 hours;
        uint256 n3 = kernel.nonces(pid);
        bytes memory s3 = _sign(pid, address(target), 1, data, d3, n3);
        vm.prank(agent);
        kernel.execute{value: 1}(pid, address(target), 1, data, d3, s3);
    }

    function testApprove_nonZero_reverts() public {
        uint256 pid = _policyWithValidator();
        vm.prank(owner);
        kernel.setCall(pid, address(target), bytes4(0x095ea7b3), true);
        vm.prank(owner);
        validator.setLimits(pid, address(0), uint128(1e18), uint128(1e18), uint32(1 days), true);
        bytes memory data = abi.encodeWithSelector(bytes4(0x095ea7b3), address(0xBEEF), uint256(123));
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = kernel.nonces(pid);
        bytes memory sig = _sign(pid, address(target), 0, data, deadline, nonce);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(SpendLimitValidator.NonZeroApprove.selector, address(target), uint256(123))
        );
        kernel.execute(pid, address(target), 0, data, deadline, sig);
    }

    function testApprove_zero_passes() public {
        uint256 pid = _policyWithValidator();

        bytes memory data = abi.encodeWithSelector(
            bytes4(0x095ea7b3), // approve(address,uint256)
            address(0xBEEF),
            uint256(0)
        );

        vm.prank(address(kernel));
        validator.validate(pid, owner, agent, address(target), 0, data);
    }

    function testTransfer_tokenLimitDisabled_reverts() public {
        uint256 pid = _policyWithValidator();
        // allow ERC20 transfer selector
        vm.prank(owner);
        kernel.setCall(pid, address(target), bytes4(0xa9059cbb), true);
        vm.prank(owner);
        validator.setLimits(pid, address(0), uint128(1e18), uint128(1e18), uint32(1 days), true);
        vm.prank(owner);
        validator.setLimits(pid, address(target), uint128(1000), uint128(1000), uint32(1 days), false);
        bytes memory data = abi.encodeWithSelector(bytes4(0xa9059cbb), address(0xCAFE), uint256(1));
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = kernel.nonces(pid);
        bytes memory sig = _sign(pid, address(target), 0, data, deadline, nonce);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SpendLimitValidator.LimitDisabled.selector, address(target)));
        kernel.execute(pid, address(target), 0, data, deadline, sig);
    }

    function testTransferFrom_tokenPerTxExceeded_reverts() public {
        uint256 pid = _policyWithValidator();
        vm.prank(owner);
        kernel.setCall(pid, address(target), bytes4(0x23b872dd), true);
        vm.prank(owner);
        validator.setLimits(pid, address(0), uint128(1e18), uint128(1e18), uint32(1 days), true);
        vm.prank(owner);
        validator.setLimits(pid, address(target), uint128(10), uint128(100), uint32(1 days), true);
        bytes memory data = abi.encodeWithSelector(bytes4(0x23b872dd), address(0x1), address(0x2), uint256(11));
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = kernel.nonces(pid);
        bytes memory sig = _sign(pid, address(target), 0, data, deadline, nonce);
        vm.prank(agent);
        vm.expectRevert();
        kernel.execute(pid, address(target), 0, data, deadline, sig);
    }

    function testTransfer_badCalldata_reverts() public {
        uint256 pid = _policyWithValidator();
        vm.prank(owner);
        kernel.setCall(pid, address(target), bytes4(0xa9059cbb), true);
        vm.prank(owner);
        validator.setLimits(pid, address(0), uint128(1e18), uint128(1e18), uint32(1 days), true);
        vm.prank(owner);
        validator.setLimits(pid, address(target), uint128(1000), uint128(1000), uint32(1 days), true);
        bytes memory data = hex"a9059cbb00000000000000000000000000000000000000000000000000000000";
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = kernel.nonces(pid);
        bytes memory sig = _sign(pid, address(target), 0, data, deadline, nonce);
        vm.prank(agent);
        vm.expectRevert(bytes("bad calldata"));
        kernel.execute(pid, address(target), 0, data, deadline, sig);
    }
}
