// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

/// @title Fixed-price feed for a test stablecoin — TESTNET ONLY
/// @notice Chainlink-compatible read interface that always reports the same price, timestamped now.
///         Used only for the demo's own test stablecoin; every other price in the demo (BNB, BUSD)
///         comes from real Chainlink feeds on BSC Testnet.
contract EPKFixedPriceFeed {
    uint8 public immutable decimals;
    int256 public immutable answer;
    string public description;

    constructor(uint8 decimals_, int256 answer_, string memory description_) {
        decimals = decimals_;
        answer = answer_;
        description = description_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}
