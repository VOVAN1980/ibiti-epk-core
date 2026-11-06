// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "../contracts/epk/EPKernel.sol";
import "../contracts/mocks/MockTarget.sol";

contract SmokeTest is Script {
    // Deterministic agent key for reproducible runs (NOT from .env)
    function _agentPk() internal pure returns (uint256) {
        return uint256(keccak256("EPK_SMOKE_AGENT_PK_V1"));
    }

    function run() external {
        uint256 ownerPk = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(ownerPk);

        uint256 agentPk = _agentPk();
        address agent = vm.addr(agentPk);

        address payable kernelAddr = payable(vm.envAddress("EPKERNEL"));
        EPKernel kernel = EPKernel(kernelAddr);

        // ----------------------------
        // OWNER phase: fund agent, setup policy
        // ----------------------------
        vm.startBroadcast(ownerPk);

        // fund agent for gas (0.001 BNB)
        payable(agent).transfer(0.001 ether);

        MockTarget target = new MockTarget();

        uint256 policyId = kernel.createPolicy(0, type(uint96).max, address(0));
        kernel.setAgent(policyId, agent, true, 0);
        kernel.setCall(policyId, address(target), MockTarget.setX.selector, true);

        // build + sign owner authorization (EIP-712)
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

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(ownerPk, digest1);
        bytes memory sig1 = abi.encodePacked(r1, s1, v1);

        vm.stopBroadcast();

        // ----------------------------
        // AGENT phase: execute
        // ----------------------------
        vm.startBroadcast(agentPk);
        kernel.execute(policyId, address(target), 0, data, deadline1, sig1);
        vm.stopBroadcast();

        // ----------------------------
        // OWNER phase: revoke
        // ----------------------------
        vm.startBroadcast(ownerPk);
        kernel.setPolicyActive(policyId, false);
        vm.stopBroadcast();

        // ----------------------------
        // Expected revert after revoke (no broadcast tx)
        // ----------------------------
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
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(ownerPk, digest2);
        bytes memory sig2 = abi.encodePacked(r2, s2, v2);

        vm.prank(agent);
        try kernel.execute(policyId, address(target), 0, data, deadline2, sig2) {
            revert("expected revert after revoke");
        } catch {}

        console2.log("EPKERNEL", address(kernel));
        console2.log("Owner", owner);
        console2.log("Agent", agent);
        console2.log("MockTarget", address(target));
        console2.log("policyId", policyId);
    }

    receive() external payable {}
}
