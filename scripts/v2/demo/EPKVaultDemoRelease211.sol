// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {EPKVault} from "../../../contracts/v2/EPKVault.sol";

/// @title EPK Vault 2.1.1 — TESTNET DEMO RELEASE
/// @notice Exists only to show a full opt-in upgrade on a public test network in minutes: the vault keeps
///         its address, funds, roles, limits and sessions; only `vaultVersion()` changes.
contract EPKVaultDemoRelease211 is EPKVault {
    function vaultVersion() public pure override returns (uint64) {
        return 20_101; // 2.1.1
    }

    /// @dev Nothing to migrate in this demo release, so the migration step is a no-op (harmless if repeated:
    ///      `migrate()` is callable only by the vault itself through its timelock).
    function _migrate(uint64) internal override {}
}
