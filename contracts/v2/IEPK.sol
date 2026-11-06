// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @notice Release catalogue a vault consults before it may run new code (see EPKRegistry).
interface IEPKRegistry {
    function isApproved(address implementation) external view returns (bool);
    function versionOf(address implementation) external view returns (uint64);
}

/// @notice Every EPKVault implementation reports its own version.
interface IVersionedVault {
    /// @return version major * 10_000 + minor * 100 + patch
    function vaultVersion() external view returns (uint64 version);
}
