// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IPolicyValidator} from "../IPolicyValidator.sol";
import {IEPKGuard} from "./IEPKGuard.sol";

/// @title EPK CompositeGuard — several guards in one slot
/// @notice Every child must accept every call (logical AND); after the batch every EPK guard child
///         checks the real balance changes. The list is fixed at deployment: a different combination is
///         a new CompositeGuard, switched in through the vault's timelock.
///
///         Children are either EPK guards (`IEPKGuard`, called with the vault they act for) or legacy
///         validators (`IPolicyValidator`: `validate` only, never `afterBatch`).
///         A composite must be used by vaults directly — composites inside composites are not supported,
///         so per-batch guard state can only ever be written for the vault that is actually executing.
contract CompositeGuard is IEPKGuard {
    uint256 public constant MAX_CHILDREN = 8;

    address[] private _children;
    bool[] private _legacy;

    error BadChildren();
    error NotVault();

    /// @param guards_ guard / validator addresses, run in this order
    /// @param legacy_ true for a validator that implements only `IPolicyValidator.validate`
    constructor(address[] memory guards_, bool[] memory legacy_) {
        uint256 n = guards_.length;
        if (n == 0 || n > MAX_CHILDREN || legacy_.length != n) revert BadChildren();
        for (uint256 i = 0; i < n; i++) {
            address c = guards_[i];
            if (c == address(0) || c == address(this) || c.code.length == 0) revert BadChildren();
            for (uint256 j = 0; j < i; j++) {
                if (guards_[j] == c) revert BadChildren();
            }
            _children.push(c);
            _legacy.push(legacy_[i]);
        }
    }

    function children() external view returns (address[] memory guards, bool[] memory legacy) {
        return (_children, _legacy);
    }

    // slither-disable-start calls-loop
    // calls-loop: at most MAX_CHILDREN fixed children chosen at deployment; a reverting child can only
    // block the vault that chose this composite.

    function validate(uint256 policyId, address signer, address agent, address target, uint256 value, bytes calldata data)
        external
    {
        _validate(msg.sender, policyId, signer, agent, target, value, data);
    }

    /// @dev Only the vault itself may speak for the vault (no nesting, see the contract notice).
    function validateFor(
        address vault,
        uint256 policyId,
        address signer,
        address agent,
        address target,
        uint256 value,
        bytes calldata data
    ) external {
        if (msg.sender != vault) revert NotVault();
        _validate(vault, policyId, signer, agent, target, value, data);
    }

    function afterBatch(uint256 policyId) external {
        _afterBatch(msg.sender, policyId);
    }

    function afterBatchFor(address vault, uint256 policyId) external {
        if (msg.sender != vault) revert NotVault();
        _afterBatch(vault, policyId);
    }

    function _validate(
        address vault,
        uint256 policyId,
        address signer,
        address agent,
        address target,
        uint256 value,
        bytes calldata data
    ) internal {
        uint256 n = _children.length;
        for (uint256 i = 0; i < n; i++) {
            if (_legacy[i]) {
                IPolicyValidator(_children[i]).validate(policyId, signer, agent, target, value, data);
            } else {
                IEPKGuard(_children[i]).validateFor(vault, policyId, signer, agent, target, value, data);
            }
        }
    }

    function _afterBatch(address vault, uint256 policyId) internal {
        uint256 n = _children.length;
        for (uint256 i = 0; i < n; i++) {
            if (!_legacy[i]) IEPKGuard(_children[i]).afterBatchFor(vault, policyId);
        }
    }
    // slither-disable-end calls-loop
}
