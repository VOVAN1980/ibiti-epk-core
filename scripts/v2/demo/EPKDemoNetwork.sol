// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

/// @title Where the demo of each test network keeps its records
/// @notice EPK is not audited: the demo scripts run only on the public test networks listed here (and on a
///         local chain), never on a mainnet. Each network keeps its own records under deployments/<network>/.
library EPKDemoNetwork {
    /// @notice deployments/<network> for this chain; reverts on any other chain.
    function dir() internal view returns (string memory) {
        uint256 id = block.chainid;
        if (id == 97) return "deployments/bsc-testnet";
        if (id == 5611) return "deployments/opbnb-testnet";
        if (id == 11155111) return "deployments/sepolia";
        if (id == 31337) return "deployments/local";
        revert("EPK: test networks only");
    }

    /// @notice deployments/<network>/<name>
    function file(string memory name) internal view returns (string memory) {
        return string.concat(dir(), "/", name);
    }
}
