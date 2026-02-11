// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Modular validator interface. Kernel must not mask reverts.
interface IPolicyValidator {
    function validate(
        uint256 policyId,
        address owner,
        address agent,
        address target,
        uint256 value,
        bytes calldata data
    ) external;
}
