// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title Which delays apply on which network
/// @notice Production delays (7-day release window, 2-day upgrade floor, 1-hour minimum timelock) apply on
///         every chain EXCEPT the public test networks listed here, where the same code runs with
///         minute-scale delays so a full release -> schedule -> upgrade cycle can be tested in minutes.
///         Unknown chains get the production delays (fail safe). Local test chains (31337) also get the
///         production delays, so the test suite always exercises the real rules.
library EPKChains {
    function isTestChain() internal view returns (bool) {
        uint256 id = block.chainid;
        return id == 97 // BNB Smart Chain Testnet
            || id == 11155111; // Ethereum Sepolia
    }
}
