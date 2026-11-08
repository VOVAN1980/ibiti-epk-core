// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

import {IPolicyValidator} from "../IPolicyValidator.sol";

/// @title EPK guard interface (guard modules for EPKVault)
/// @notice A guard is an external, immutable rule set that a vault consults for a policy or a session
///         envelope. It can only REJECT (revert); it never moves funds and holds no vault permissions.
///
///         Call order inside one `EPKVault.execute` (vault 2.1.0+):
///           1. `validate(...)` once per call of the batch, before anything runs
///           2. the calls run
///           3. `afterBatch(policyId)` once, so the guard can check the real balance changes
///
///         Vault 2.0.x only calls `validate`. Guards must stay safe in that case (they then rely on
///         their pre-checks alone) and must not keep state that `afterBatch` would have cleared.
///
///         `validateFor` / `afterBatchFor` are the same hooks for a guard that sits inside a
///         `CompositeGuard`: the composite passes the vault it is acting for. Any per-batch state is
///         keyed by (caller, vault), so nobody can write into another caller's slot.
interface IEPKGuard is IPolicyValidator {
    function validateFor(
        address vault,
        uint256 policyId,
        address signer,
        address agent,
        address target,
        uint256 value,
        bytes calldata data
    ) external;

    function afterBatch(uint256 policyId) external;

    function afterBatchFor(address vault, uint256 policyId) external;
}
