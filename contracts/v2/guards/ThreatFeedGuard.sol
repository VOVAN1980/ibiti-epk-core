// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IEPKGuard} from "./IEPKGuard.sol";

/// @title EPK ThreatFeed V2 — shared blocklist guard
/// @notice A blocklist of dangerous addresses (drainer contracts, phishing receivers, exploited tokens)
///         that many vaults can subscribe to by adding this guard to a policy or a session envelope.
///
///         - Blocking is INSTANT: the owner or any blocker (fast responders) can block.
///         - Unblocking is SLOW: only the owner can schedule it, it waits `unblockDelay`, and any
///           blocker can cancel it meanwhile — a stolen owner key cannot quietly open a blocked address.
///         - The feed can only stop calls, never move funds (the same trust level as a vault guardian).
///
///         Checked for every call: the call target, and every 32-byte argument word that has the shape
///         of an address — so recipients, spenders and addresses nested in arrays or structs
///         (e.g. a swap path or a multicall payload) are covered without decoding each protocol.
contract ThreatFeedGuard is IEPKGuard {
    uint256 public constant MIN_UNBLOCK_DELAY = 1 hours;
    uint256 public constant MAX_BATCH = 256;

    uint256 public immutable unblockDelay;

    address public owner;
    address public pendingOwner;
    mapping(address => bool) public isBlocker;
    mapping(address => bool) public blocked;
    /// @notice When a scheduled unblock may be executed (0 = none scheduled).
    mapping(address => uint256) public unblockReadyAt;

    event Blocked(address indexed account, address indexed by, bytes32 reason);
    event UnblockScheduled(address indexed account, uint256 readyAt);
    event UnblockCancelled(address indexed account, address indexed by);
    event Unblocked(address indexed account);
    event BlockerSet(address indexed blocker, bool enabled);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotOwnerOrBlocker();
    error ZeroAddress();
    error BadDelay();
    error TooMany();
    error NotBlocked(address account);
    error NotScheduled(address account);
    error NotReady(address account, uint256 readyAt);
    error BlockedAddress(address account);

    constructor(address initialOwner, uint256 unblockDelay_) {
        if (initialOwner == address(0)) revert ZeroAddress();
        if (unblockDelay_ < MIN_UNBLOCK_DELAY || unblockDelay_ > 30 days) revert BadDelay();
        owner = initialOwner;
        unblockDelay = unblockDelay_;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOwnerOrBlocker() {
        if (msg.sender != owner && !isBlocker[msg.sender]) revert NotOwnerOrBlocker();
        _;
    }

    // ------------------------------------------------------------------ feed management

    /// @notice Block addresses now. A pending unblock of any of them is cancelled.
    function blockAddresses(address[] calldata accounts, bytes32 reason) external onlyOwnerOrBlocker {
        if (accounts.length > MAX_BATCH) revert TooMany();
        for (uint256 i = 0; i < accounts.length; i++) {
            address a = accounts[i];
            if (a == address(0)) revert ZeroAddress();
            blocked[a] = true;
            unblockReadyAt[a] = 0;
            emit Blocked(a, msg.sender, reason);
        }
    }

    /// @notice Start the unblock delay for blocked addresses.
    function scheduleUnblock(address[] calldata accounts) external onlyOwner {
        if (accounts.length > MAX_BATCH) revert TooMany();
        uint256 readyAt = block.timestamp + unblockDelay;
        for (uint256 i = 0; i < accounts.length; i++) {
            address a = accounts[i];
            if (!blocked[a]) revert NotBlocked(a);
            unblockReadyAt[a] = readyAt;
            emit UnblockScheduled(a, readyAt);
        }
    }

    /// @notice Veto a scheduled unblock (owner or any blocker).
    function cancelUnblock(address[] calldata accounts) external onlyOwnerOrBlocker {
        if (accounts.length > MAX_BATCH) revert TooMany();
        for (uint256 i = 0; i < accounts.length; i++) {
            address a = accounts[i];
            if (unblockReadyAt[a] == 0) revert NotScheduled(a);
            unblockReadyAt[a] = 0;
            emit UnblockCancelled(a, msg.sender);
        }
    }

    // slither-disable-start timestamp,incorrect-equality
    // timestamp: the unblock delay is hours to days; a few seconds of validator skew are irrelevant.
    // incorrect-equality: `readyAt == 0` compares with the "nothing scheduled" sentinel, not a balance.
    /// @notice Finish unblocks whose delay has passed (anyone may call: the decision was the owner's).
    function executeUnblock(address[] calldata accounts) external {
        if (accounts.length > MAX_BATCH) revert TooMany();
        for (uint256 i = 0; i < accounts.length; i++) {
            address a = accounts[i];
            uint256 readyAt = unblockReadyAt[a];
            if (readyAt == 0) revert NotScheduled(a);
            if (block.timestamp < readyAt) revert NotReady(a, readyAt);
            blocked[a] = false;
            unblockReadyAt[a] = 0;
            emit Unblocked(a);
        }
    }
    // slither-disable-end timestamp,incorrect-equality

    /// @notice Blockers are fast responders: they can block and veto unblocks, nothing else.
    function setBlocker(address blocker, bool enabled) external onlyOwner {
        if (blocker == address(0)) revert ZeroAddress();
        isBlocker[blocker] = enabled;
        emit BlockerSet(blocker, enabled);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ------------------------------------------------------------------ guard hooks

    function validate(uint256, address, address, address target, uint256, bytes calldata data) external view {
        _check(target, data);
    }

    function validateFor(address, uint256, address, address, address target, uint256, bytes calldata data)
        external
        view
    {
        _check(target, data);
    }

    /// @dev Stateless guard: nothing to check after the batch.
    function afterBatch(uint256) external pure {}

    function afterBatchFor(address, uint256) external pure {}

    /// @notice True if `target` or any address-shaped argument word of `data` is blocked.
    function isCallBlocked(address target, bytes calldata data) external view returns (bool) {
        if (blocked[target]) return true;
        for (uint256 off = 4; off + 32 <= data.length; off += 32) {
            uint256 w = uint256(bytes32(data[off:off + 32]));
            if (w >> 160 == 0 && w != 0 && blocked[address(uint160(w))]) return true;
        }
        return false;
    }

    function _check(address target, bytes calldata data) internal view {
        if (blocked[target]) revert BlockedAddress(target);
        for (uint256 off = 4; off + 32 <= data.length; off += 32) {
            uint256 w = uint256(bytes32(data[off:off + 32]));
            if (w >> 160 == 0 && w != 0 && blocked[address(uint160(w))]) revert BlockedAddress(address(uint160(w)));
        }
    }
}
