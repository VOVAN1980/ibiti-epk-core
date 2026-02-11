// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPolicyValidator} from "../epk/IPolicyValidator.sol";

contract TargetSelectorGuard is IPolicyValidator {
    address public owner;
    address public immutable authorizedCaller; // kernel OR composite

    mapping(bytes4 => bool) public blockedSelector;
    mapping(uint256 => mapping(bytes32 => bool)) public blockedCallKey;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error UnauthorizedCaller();
    error BlockedSelector(bytes4 selector);
    error BlockedCall(uint256 policyId, bytes32 callKey);

    constructor(address _authorizedCaller, address initialOwner) {
        require(_authorizedCaller != address(0), "zero caller");
        require(initialOwner != address(0), "zero owner");
        authorizedCaller = _authorizedCaller;
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);

        blockedSelector[0x095ea7b3] = true; // approve
        blockedSelector[0x39509351] = true; // increaseAllowance
        blockedSelector[0xa457c2d7] = true; // decreaseAllowance
        blockedSelector[0xd505accf] = true; // permit (EIP-2612)
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setBlockedSelector(bytes4 selector, bool blocked) external onlyOwner {
        blockedSelector[selector] = blocked;
    }

    function setBlockedCallKey(uint256 policyId, address target, bytes4 selector, bool blocked) external onlyOwner {
        bytes32 key = keccak256(abi.encodePacked(target, selector));
        blockedCallKey[policyId][key] = blocked;
    }

    function validate(
        uint256 policyId,
        address,
        address,
        address target,
        uint256,
        bytes calldata data
    ) external view override {
        if (msg.sender != authorizedCaller) revert UnauthorizedCaller();
        if (data.length < 4) revert BlockedSelector(0x00000000);

        bytes4 selector = bytes4(data[:4]);
        if (blockedSelector[selector]) revert BlockedSelector(selector);

        bytes32 key = keccak256(abi.encodePacked(target, selector));
        if (blockedCallKey[policyId][key]) revert BlockedCall(policyId, key);
    }
}
