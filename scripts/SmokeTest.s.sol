// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "../contracts/epk/EPKernel.sol";
import "../contracts/mocks/MockTarget.sol";

contract SmokeTest is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address payable kernelAddr = payable(vm.envAddress("EPKERNEL"));
        EPKernel kernel = EPKernel(kernelAddr);

        address owner = vm.addr(pk);

        // --- BROADCAST SECTION (only successful txs)
        vm.startBroadcast(pk);

        MockTarget target = new MockTarget();

        uint256 policyId = kernel.createPolicy(0, type(uint96).max, address(0));
        kernel.setAgent(policyId, owner, true, 0);
        kernel.setCall(policyId, address(target), MockTarget.setX.selector, true);

        bytes memory data = abi.encodeCall(MockTarget.setX, (uint256(123)));
        uint256 deadline1 = block.timestamp + 1 hours;

        uint256 nonce1 = kernel.nonces(policyId);
        bytes32 digest1 = kernel.getTypedDataHash(
            policyId,
            address(target),
            0,
            keccak256(data),
            nonce1,
            deadline1
        );
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(pk, digest1);
        bytes memory sig1 = abi.encodePacked(r1, s1, v1);

        kernel.execute(policyId, address(target), 0, data, deadline1, sig1);

        kernel.setPolicyActive(policyId, false);

        vm.stopBroadcast();

        // --- NO-BROADCAST CHECK (call only, revert expected)
        uint256 deadline2 = block.timestamp + 1 hours;
        uint256 nonce2 = kernel.nonces(policyId);

        bytes32 digest2 = kernel.getTypedDataHash(
            policyId,
            address(target),
            0,
            keccak256(data),
            nonce2,
            deadline2
        );
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(pk, digest2);
        bytes memory sig2 = abi.encodePacked(r2, s2, v2);

        // simulate "agent call" without sending a tx
        vm.prank(owner);
        try kernel.execute(policyId, address(target), 0, data, deadline2, sig2) {
            revert("expected revert after revoke");
        } catch {}

        console2.log("EPKERNEL", address(kernel));
        console2.log("MockTarget", address(target));
        console2.log("policyId", policyId);
    }
}
