// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EPKVault, IEPKRegistry} from "./EPKVault.sol";

/// @title EPK Vault proxy — permanent address of one customer's vault
/// @dev Plain native transfers are accepted here without touching the implementation, so senders
///      limited to the 2300-gas stipend (`transfer` / `send`) can always pay the vault.
contract EPKVaultProxy is ERC1967Proxy {
    constructor(address implementation, bytes memory data) payable ERC1967Proxy(implementation, data) {}

    receive() external payable {}
}

/// @title EPK Vault factory — one isolated vault per customer
/// @notice Deploys each vault as an ERC-1967 proxy (permanent address, cheap to create) pointing at a
///         fixed implementation, and only while the registry still approves it. The factory has no
///         owner and no upgrade power: each vault upgrades only by its own decision.
///         The caller always becomes the vault's admin, so nobody can create a vault "for" someone
///         else with guardians they did not choose, and the CREATE2 salt is bound to the caller.
contract EPKVaultFactory {
    address public immutable implementation;
    address public immutable registry;

    /// @notice Created by this factory. Not a trust signal on its own: integrators should also check
    ///         the vault's registry and its current ERC-1967 implementation.
    mapping(address => bool) public isVault;

    event VaultCreated(address indexed vault, address indexed admin, uint256 delay, address recovery);

    error ZeroAddress();
    error ImplementationNotApproved(address implementation);

    constructor(address implementation_, address registry_) {
        if (implementation_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        implementation = implementation_;
        registry = registry_;
    }

    function createVault(address[] calldata guardians, uint256 delay, address recovery, bytes32 salt)
        external
        returns (address vault)
    {
        if (!IEPKRegistry(registry).isApproved(implementation)) revert ImplementationNotApproved(implementation);
        vault = address(
            new EPKVaultProxy{salt: _salt(msg.sender, salt)}(
                implementation, _initData(msg.sender, guardians, delay, recovery)
            )
        );
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
            abi.encodePacked(
                type(EPKVaultProxy).creationCode,
                abi.encode(implementation, _initData(admin, guardians, delay, recovery))
            )
        );
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(admin, salt), initCodeHash));
        return address(uint160(uint256(h)));
    }

    function _initData(address admin, address[] calldata guardians, uint256 delay, address recovery)
        private
        view
        returns (bytes memory)
    {
        return abi.encodeCall(EPKVault.initialize, (admin, guardians, delay, recovery, registry));
    }

    function _salt(address admin, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(admin, salt));
    }
}
