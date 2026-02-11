// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPolicyValidator} from "../epk/IPolicyValidator.sol";

/// @notice Minimal Ownable (no external dependencies).
abstract contract OwnableLite {
    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();

    constructor(address initialOwner) {
        require(initialOwner != address(0), "zero owner");
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
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
}

/// @notice Composite validator: Kernel calls this, it calls child validators in order.
/// @dev Child validators must accept msg.sender == this (their authorizedCaller).
contract CompositeValidator is IPolicyValidator, OwnableLite {
    address public immutable kernel;
    address[] public validators;

    event ValidatorsSet(address[] validators);

    error UnauthorizedCaller();
    error ZeroValidator();

    constructor(address _kernel, address initialOwner, address[] memory _validators) OwnableLite(initialOwner) {
        require(_kernel != address(0), "zero kernel");
        kernel = _kernel;
        _setValidators(_validators);
    }

    function validatorsLength() external view returns (uint256) {
        return validators.length;
    }

    function setValidators(address[] calldata _validators) external onlyOwner {
        _setValidators(_validators);
    }

    function _setValidators(address[] memory _validators) internal {
        delete validators;
        for (uint256 i = 0; i < _validators.length; i++) {
            if (_validators[i] == address(0)) revert ZeroValidator();
            validators.push(_validators[i]);
        }
        emit ValidatorsSet(_validators);
    }

    function validate(
        uint256 policyId,
        address owner_,
        address agent,
        address target,
        uint256 value,
        bytes calldata data
    ) external override {
        if (msg.sender != kernel) revert UnauthorizedCaller();

        for (uint256 i = 0; i < validators.length; i++) {
            IPolicyValidator(validators[i]).validate(policyId, owner_, agent, target, value, data);
        }
    }
}
