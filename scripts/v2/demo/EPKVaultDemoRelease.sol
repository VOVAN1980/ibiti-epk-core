// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {EPKVault} from "../../../contracts/v2/EPKVault.sol";

/// @title EPK Vault 2.0.1 — TESTNET DEMO RELEASE
/// @notice Exists only to demonstrate an opt-in upgrade on testnet: the vault keeps its address,
///         funds, roles, limits and sessions; only `vaultVersion()` and `releaseNote()` change.
contract EPKVaultDemoRelease is EPKVault {
    function vaultVersion() public pure override returns (uint64) {
        return 20_001; // 2.0.1
    }

    function releaseNote() external pure returns (string memory) {
        return "EPK Vault 2.0.1 - testnet demo release (opt-in upgrade, same address)";
    }

    /// @dev Nothing to migrate in this demo; reinitializer(2) marks the migration as done.
    function _migrate(uint64) internal override reinitializer(2) {}
}
