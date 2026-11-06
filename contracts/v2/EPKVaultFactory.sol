// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EPKVault} from "./EPKVault.sol";

/// @title EPK Vault factory — one isolated vault per customer
/// @notice Deterministic (CREATE2) deployment. The caller always becomes the vault's admin, so
///         nobody can create a vault "for" someone else with guardians they did not choose, and the
///         salt is bound to the caller, so nobody can squat another customer's predicted address.
contract EPKVaultFactory {
    mapping(address => bool) public isVault;

    event VaultCreated(address indexed vault, address indexed admin, uint256 delay, address recovery);

    function createVault(address[] calldata guardians, uint256 delay, address recovery, bytes32 salt)
        external
        returns (address vault)
    {
        vault = address(new EPKVault{salt: _salt(msg.sender, salt)}(msg.sender, guardians, delay, recovery));
        isVault[vault] = true;
        emit VaultCreated(vault, msg.sender, delay, recovery);
    }

    function predictVaultAddress(
        address admin,
        address[] calldata guardians,
        uint256 delay,
        address recovery,
        bytes32 salt
    ) external view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(EPKVault).creationCode, abi.encode(admin, guardians, delay, recovery))
        );
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(admin, salt), initCodeHash));
        return address(uint160(uint256(h)));
    }

    function _salt(address admin, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(admin, salt));
    }
}
