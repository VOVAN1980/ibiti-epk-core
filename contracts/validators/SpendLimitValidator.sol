// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPolicyValidator} from "../epk/IPolicyValidator.sol";

/// @notice Spend limit validator (rolling window). v1 reference.
/// @dev token == address(0) means native value.
/// @dev This validator is gated: only `authorizedCaller` may call validate().
contract SpendLimitValidator is IPolicyValidator {
    address public owner;
    address public immutable authorizedCaller; // kernel OR composite

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // token=address(0) means native value.
    struct Limits {
        uint128 maxPerTx;
        uint128 maxPerWindow;
        uint32 windowSeconds;
        bool enabled;
    }

    struct WindowState {
        uint64 windowStart;
        uint192 spent;
    }

    mapping(uint256 => mapping(address => Limits)) public limits;
    mapping(uint256 => mapping(address => WindowState)) public windowState;

    event SpendUpdated(uint256 indexed policyId, address indexed token, uint192 newSpent, uint64 windowStart);

    error NotOwner();
    error UnauthorizedCaller();
    error LimitDisabled(address token);
    error PerTxExceeded(address token, uint256 amount, uint256 maxPerTx);
    error PerWindowExceeded(address token, uint256 newSpent, uint256 maxPerWindow);
    error NonZeroApprove(address token, uint256 amount);

    constructor(address _authorizedCaller, address initialOwner) {
        require(_authorizedCaller != address(0), "zero caller");
        require(initialOwner != address(0), "zero owner");
        authorizedCaller = _authorizedCaller;
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setLimits(
        uint256 policyId,
        address token,
        uint128 maxPerTx,
        uint128 maxPerWindow,
        uint32 windowSeconds,
        bool enabled
    ) external onlyOwner {
        require(windowSeconds > 0, "window=0");
        limits[policyId][token] =
            Limits({maxPerTx: maxPerTx, maxPerWindow: maxPerWindow, windowSeconds: windowSeconds, enabled: enabled});
    }

    function validate(uint256 policyId, address, address, address target, uint256 value, bytes calldata data)
        external
        override
    {
        if (msg.sender != authorizedCaller) revert UnauthorizedCaller();

        // 1) Native value rolling window
        if (value > 0) _checkAndUpdate(policyId, address(0), value);

        if (data.length < 4) return;
        bytes4 sel = bytes4(data[:4]);

        // 2) Harden: forbid any non-zero approve in this policy flow
        // approve(spender, amount)
        if (sel == 0x095ea7b3) {
            uint256 amount = _readUint256Arg(data, 1);
            if (amount > 0) revert NonZeroApprove(target, amount);
            return;
        }

        // 3) ERC20 transfers only (reference)
        // transfer(to, amount)
        if (sel == 0xa9059cbb) {
            uint256 amount = _readUint256Arg(data, 1);
            _checkAndUpdate(policyId, target, amount); // token == target
        }
        // transferFrom(from, to, amount)
        else if (sel == 0x23b872dd) {
            uint256 amount = _readUint256Arg(data, 2);
            _checkAndUpdate(policyId, target, amount); // token == target
        }
    }

    function _checkAndUpdate(uint256 policyId, address token, uint256 amount) internal {
        Limits memory L = limits[policyId][token];
        if (!L.enabled) revert LimitDisabled(token);
        if (amount > L.maxPerTx) revert PerTxExceeded(token, amount, L.maxPerTx);

        WindowState storage W = windowState[policyId][token];

        if (W.windowStart == 0 || block.timestamp > uint256(W.windowStart) + uint256(L.windowSeconds)) {
            if (amount > L.maxPerWindow) revert PerWindowExceeded(token, amount, L.maxPerWindow);
            W.windowStart = uint64(block.timestamp);
            W.spent = uint192(amount);
        } else {
            uint256 newSpent = uint256(W.spent) + amount;
            if (newSpent > L.maxPerWindow) revert PerWindowExceeded(token, newSpent, L.maxPerWindow);
            W.spent = uint192(newSpent);
        }

        emit SpendUpdated(policyId, token, W.spent, W.windowStart);
    }

    function _readUint256Arg(bytes calldata data, uint256 argIndex) internal pure returns (uint256 v) {
        uint256 offset = 4 + 32 * argIndex;
        require(data.length >= offset + 32, "bad calldata");
        assembly {
            v := calldataload(add(data.offset, offset))
        }
    }
}
