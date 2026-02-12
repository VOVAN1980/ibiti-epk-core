// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPolicyValidator} from "../epk/IPolicyValidator.sol";

contract ThreatFeedBlocklistValidator is IPolicyValidator {
    address public owner;
    address public immutable authorizedCaller; // kernel OR composite

    bytes32 public root;
    uint256 public epoch;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event RootUpdated(bytes32 indexed newRoot, uint256 indexed newEpoch);

    error NotOwner();
    error UnauthorizedCaller();
    error Blocklisted(bytes32 itemHash);

    constructor(address _authorizedCaller, address initialOwner, bytes32 initialRoot, uint256 initialEpoch) {
        require(_authorizedCaller != address(0), "zero caller");
        require(initialOwner != address(0), "zero owner");
        authorizedCaller = _authorizedCaller;
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);

        root = initialRoot;
        epoch = initialEpoch;
        emit RootUpdated(initialRoot, initialEpoch);
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

    function updateRoot(bytes32 newRoot, uint256 newEpoch) external onlyOwner {
        root = newRoot;
        epoch = newEpoch;
        emit RootUpdated(newRoot, newEpoch);
    }

    function validate(uint256, address, address, address target, uint256, bytes calldata data) external view override {
        if (msg.sender != authorizedCaller) revert UnauthorizedCaller();
        if (data.length < 4) return;
        if (root == bytes32(0)) return;

        bytes4 selector = bytes4(data[:4]);
        bytes32 itemHash = keccak256(abi.encodePacked(target, selector));

        if (itemHash == root) revert Blocklisted(itemHash);
    }
}
