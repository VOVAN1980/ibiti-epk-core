// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "../contracts/validators/SpendLimitValidator.sol";
contract SpendLimitValidatorReadArgTest is Test {
    SpendLimitValidator v;
    address owner = address(0xA11CE);
    uint256 pid = 1;
    address token = address(0xBEEF);
    function setUp() public {
        // authorize this test contract as caller
        v = new SpendLimitValidator(address(this), owner);
        vm.prank(owner);
        v.setLimits(pid, token, uint128(1000), uint128(5000), uint32(1 days), true);
    }
    function test_readUintArg_transfer_hits_line_137() public {
        // transfer(address to, uint256 amount)
        bytes memory data = abi.encodeWithSelector(0xa9059cbb, address(0xCAFE), uint256(123));
        // direct call validate => _readUint256Arg(...,1) => calldataload line
        v.validate(pid, address(0), address(0), token, 0, data);
    }
    function test_readUintArg_transferFrom_hits_line_137() public {
        // transferFrom(address from,address to,uint256 amount)
        bytes memory data = abi.encodeWithSelector(
            0x23b872dd,
            address(0x1111),
            address(0x2222),
            uint256(321)
        );
        // direct call validate => _readUint256Arg(...,2) => calldataload line
        v.validate(pid, address(0), address(0), token, 0, data);
    }
}