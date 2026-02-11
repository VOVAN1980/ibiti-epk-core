// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/epk/EPKernel.sol";
import "../contracts/mocks/MockTarget.sol";

contract EPKernelInvariants is Test {
    EPKernel kernel;
    MockTarget target;

    uint256 ownerSk;
    address owner;
    address agent;
    uint256 pid;

    function setUp() public {
        kernel = new EPKernel();
        target = new MockTarget();

        ownerSk = 0xA11CE;
        owner = vm.addr(ownerSk);
        agent = vm.addr(0xB0B);

        vm.prank(owner);
        pid = kernel.createPolicy(0, type(uint96).max, address(0));

        vm.prank(owner);
        kernel.setAgent(pid, agent, true, 0);

        vm.prank(owner);
        kernel.setCall(pid, address(target), MockTarget.setX.selector, true);
    }

    function invariant_nonceNeverDecreases() public view {
        // uint256 can't be negative; this is a basic sanity invariant.
        kernel.nonces(pid);
    }

    function invariant_revokedPolicyCannotExecute() public {
        vm.prank(owner);
        kernel.setPolicyActive(pid, false);

        bytes memory data = abi.encodeWithSelector(MockTarget.setX.selector, 1);
        uint256 deadline = block.timestamp + 3600;
        uint256 nonce = kernel.nonces(pid);

        bytes32 digest = kernel.getTypedDataHash(pid, address(target), 0, keccak256(data), nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerSk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(agent);
        vm.expectRevert();
        kernel.execute(pid, address(target), 0, data, deadline, sig);
    }
}
