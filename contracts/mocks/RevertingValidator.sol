// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../epk/EPKernel.sol";

contract RevertingValidator is IPolicyValidator {
    error ValidatorRejected();

    function validate(
        uint256,
        address,
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override {
        revert ValidatorRejected();
    }
}
