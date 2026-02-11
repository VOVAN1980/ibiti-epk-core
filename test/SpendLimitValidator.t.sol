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
    function _sign(
        uint256 pid,
        address tgt,
        uint256 value,
        bytes memory data,
        uint256 deadline,
        uint256 nonce
    ) internal view returns (bytes memory sig) {
        bytes32 digest = kernel.getTypedDataHash(
            pid,
            tgt,
            value,
            keccak256(data),
            nonce,
            deadline
        );
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
        // включаем лимиты для native token (address(0))
        vm.prank(owner);
        validator.setLimits(pid, address(0), uint128(1 ether), uint32(2_000_000_000), uint32(1 days), true);
    }
    function testSpendLimit_perTx_native() public {
        uint256 pid = _policyWithValidator();
        // лимит perTx = 1000 (wei/units), окно большое чтобы не мешало
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
        // perTx высокий, окно = 2000
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
        // 2) 1000 ok (итого 2000)
        uint256 d2 = block.timestamp + 1 hours;
        uint256 n2 = kernel.nonces(pid);
        bytes memory s2 = _sign(pid, address(target), 1000, data, d2, n2);
        vm.prank(agent);
        kernel.execute{value: 1000}(pid, address(target), 1000, data, d2, s2);
        // 3) +1 => реверт (PerWindowExceeded)
        uint256 d3 = block.timestamp + 1 hours;
        uint256 n3 = kernel.nonces(pid);
        bytes memory s3 = _sign(pid, address(target), 1, data, d3, n3);
        vm.prank(agent);
        vm.expectRevert();
        kernel.execute{value: 1}(pid, address(target), 1, data, d3, s3);
    }
}