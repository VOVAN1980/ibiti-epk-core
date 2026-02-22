// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "../contracts/validators/SpendLimitValidator.sol";

contract SpendLimitValidatorReadArgTest is Test {
    SpendLimitValidator v;
    address owner = address(0xA11CE);
    uint256 pid = 1;
    address TOKEN0 = address(0xBEEF);

    function setUp() public {
        // authorize this test contract as caller
        v = new SpendLimitValidator(address(this), owner);
        vm.prank(owner);
        v.setLimits(pid, TOKEN0, uint128(1000), uint128(5000), uint32(1 days), true);
    }

    function test_readUintArg_transfer_hits_line_137() public {
        // transfer(address to, uint256 amount)
        bytes memory data = abi.encodeWithSelector(0xa9059cbb, address(0xCAFE), uint256(123));
        // direct call validate => _readUint256Arg(...,1) => calldataload line
        v.validate(pid, address(0), address(0), TOKEN0, 0, data);
    }

    function test_readUintArg_transferFrom_hits_line_137() public {
        // transferFrom(address from,address to,uint256 amount)
        bytes memory data = abi.encodeWithSelector(0x23b872dd, address(0x1111), address(0x2222), uint256(321));
        // direct call validate => _readUint256Arg(...,2) => calldataload line
        v.validate(pid, address(0), address(0), TOKEN0, 0, data);
    }
    // ---------------- extra coverage: readUint256Arg + branches ----------------
    function test_validate_dataTooShort_returns_noRevert() public {
        bytes memory data = hex"01";
        v.validate(pid, address(0), address(0), address(0x1234), 0, data);
    }
    function test_validate_unknownSelector_noRevert() public {
        bytes memory data = abi.encodePacked(bytes4(0xdeadbeef), bytes32(uint256(1)));
        v.validate(pid, address(0), address(0), address(0x1234), 0, data);
    }
    function test_validate_unauthorizedCaller_reverts() public {
        bytes memory data = abi.encodeWithSelector(bytes4(0xa9059cbb), address(0xCAFE), uint256(1)); // transfer
        vm.prank(address(0xBEEF));
        vm.expectRevert(SpendLimitValidator.UnauthorizedCaller.selector);
        v.validate(pid, address(0), address(0), address(0x1234), 0, data);
    }
    function test_setLimits_windowZero_reverts() public {
        vm.prank(owner);
        vm.expectRevert(bytes("window=0"));
        v.setLimits(pid, address(0x1234), 1000, 1000, 0, true);
    }
    function test_transferOwnership_zeroOwner_reverts() public {
        vm.prank(owner);
        vm.expectRevert(bytes("zero owner"));
        v.transferOwnership(address(0));
    }
    function test_readUintArg_transfer_badCalldata_reverts() public {
        vm.prank(owner);
        v.setLimits(pid, address(0x1234), 1000, 2000, 86400, true);
        bytes memory data = abi.encodePacked(bytes4(0xa9059cbb)); // only selector
        vm.expectRevert(bytes("bad calldata"));
        v.validate(pid, address(0), address(0), address(0x1234), 0, data);
    }
    function test_readUintArg_transferFrom_badCalldata_reverts() public {
        vm.prank(owner);
        v.setLimits(pid, address(0x5678), 1000, 2000, 86400, true);
        bytes memory data = abi.encodePacked(bytes4(0x23b872dd)); // only selector
        vm.expectRevert(bytes("bad calldata"));
        v.validate(pid, address(0), address(0), address(0x5678), 0, data);
    }
    function test_readUintArg_approve_badCalldata_reverts() public {
        vm.prank(owner);
        v.setLimits(pid, address(0xABCD), 1000, 2000, 86400, true);
        bytes memory data = abi.encodePacked(bytes4(0x095ea7b3)); // only selector
        vm.expectRevert(bytes("bad calldata"));
        v.validate(pid, address(0), address(0), address(0xABCD), 0, data);
    }
    function test_approve_zero_passes_and_nonZero_reverts() public {
        vm.prank(owner);
        v.setLimits(pid, TOKEN0, 1000, 2000, 86400, true);
        // approve(spender,0) passes
        bytes memory okData = abi.encodeWithSelector(bytes4(0x095ea7b3), address(0xCAFE), uint256(0));
        v.validate(pid, address(0), address(0), TOKEN0, 0, okData);
        // approve(spender,>0) reverts NonZeroApprove(TOKEN0, amount)
        bytes memory badData = abi.encodeWithSelector(bytes4(0x095ea7b3), address(0xCAFE), uint256(1));
        vm.expectRevert(abi.encodeWithSelector(SpendLimitValidator.NonZeroApprove.selector, TOKEN0, uint256(1)));
        v.validate(pid, address(0), address(0), TOKEN0, 0, badData);
    }
    function test_token_transfer_updatesWindowState_readsIndex1_success() public {
        vm.prank(owner);
        v.setLimits(pid, TOKEN0, 1000, 2000, 86400, true);
        bytes memory data = abi.encodeWithSelector(bytes4(0xa9059cbb), address(0xCAFE), uint256(123)); // transfer(to,amount)
        v.validate(pid, address(0), address(0), TOKEN0, 0, data);
        (, uint192 spentNow) = v.windowState(pid, TOKEN0);
        assertEq(uint256(spentNow), 123);
    }
    function test_token_transferFrom_updatesWindowState_readsIndex2_success() public {
        vm.prank(owner);
        v.setLimits(pid, TOKEN0, 1000, 2000, 86400, true);
        bytes memory data =
            abi.encodeWithSelector(bytes4(0x23b872dd), address(0x1111), address(0x2222), uint256(77)); // transferFrom(from,to,amount)
        v.validate(pid, address(0), address(0), TOKEN0, 0, data);
        (, uint192 spentNow) = v.windowState(pid, TOKEN0);
        assertEq(uint256(spentNow), 77);
    }
    function test_native_perWindowExceeded_onFirstSpend_hitsResetBranch() public {
        vm.prank(owner);
        v.setLimits(pid, address(0), 10_000, 100, 86400, true);
        bytes memory data = hex"12345678"; // irrelevant
        vm.expectRevert(abi.encodeWithSelector(SpendLimitValidator.PerWindowExceeded.selector, address(0), uint256(101), uint256(100)));
        v.validate(pid, address(0), address(0), address(0), 101, data);
    }
    function test_native_perWindowExceeded_onAccumulation_hitsElseBranch() public {
        vm.prank(owner);
        v.setLimits(pid, address(0), 10_000, 200, 86400, true);
        bytes memory data = hex"12345678";
        v.validate(pid, address(0), address(0), address(0), 150, data);
        vm.expectRevert(abi.encodeWithSelector(SpendLimitValidator.PerWindowExceeded.selector, address(0), uint256(250), uint256(200)));
        v.validate(pid, address(0), address(0), address(0), 100, data);
    }
}



