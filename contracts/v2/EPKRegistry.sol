// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

import {IEPKRegistry, IVersionedVault} from "./IEPK.sol";
import {EPKChains} from "./EPKChains.sol";

/// @title EPK Registry — catalogue of reviewed EPKVault implementations
/// @notice Lists the implementation versions that vaults MAY opt into. The registry cannot upgrade,
///         pause or touch any vault: every vault decides for itself (admin + timelock + guardian veto).
///         A vault's registry is fixed at creation and cannot be swapped.
///         A new release becomes usable only `approvalDelay()` after it is proposed (7 days; minutes
///         on public test networks, see EPKChains), so the public can inspect it first; a release can be
///         revoked instantly (blocks future opt-ins only).
///         Fast track for urgent security fixes: a security council (a multisig, fixed at
///         creation; none = no fast track) may make an already-proposed PATCH release usable at once. The
///         owner key alone cannot skip the window, the council alone cannot list code, and every vault
///         still opts in itself; from vault release 2.4.0 it waits only its own timelock for such a fix
///         (1 hour minimum on mainnets), and its guardians can veto. The council may also revoke a
///         release instantly.
contract EPKRegistry is IEPKRegistry {
    struct Release {
        uint64 version; // read from the implementation's own vaultVersion(); 0 = not listed
        uint64 activeAt;
        bool revoked;
        bytes32 codehash; // pinned at proposal time
    }

    uint256 public constant APPROVAL_DELAY = 7 days;
    /// @notice Release window on public test networks only (EPKChains.isTestChain).
    uint256 public constant TEST_APPROVAL_DELAY = 5 minutes;
    /// @notice Largest version jump per release (one major version), so the version space cannot be
    ///         exhausted by a single malicious proposal.
    uint64 public constant MAX_VERSION_STEP = 10_000;

    /// @notice Security council (a multisig, held apart from the owner key); address(0) = no fast track.
    ///         Fixed at creation.
    address public immutable council;
    address public owner;
    address public pendingOwner;
    uint64 public latestVersion;
    mapping(address => Release) public releases;
    /// @notice The latest version listed before each release: a fast-tracked release must be a patch of it.
    mapping(address => uint64) public previousVersionOf;
    /// @notice Releases the security council fast-tracked as urgent fixes: from vault release 2.4.0 a vault
    ///         installs them after its own timelock (1 hour minimum on mainnets) instead of the 2-day upgrade wait.
    mapping(address => bool) public override isUrgent;

    event ReleaseProposed(address indexed implementation, uint64 version, uint64 activeAt, bytes32 codehash);
    event ReleaseRevoked(address indexed implementation, uint64 version);
    event ReleaseFastTracked(address indexed implementation, uint64 version);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error NoCode(address implementation);
    error DelegatedCode(address implementation);
    error NotAVault(address implementation);
    error VersionNotHigher(uint64 latest, uint64 proposed);
    error VersionStepTooLarge(uint64 latest, uint64 proposed);
    error AlreadyListed(address implementation);
    error UnknownRelease(address implementation);
    error NotCouncil();
    error NotOwnerOrCouncil();
    error NotPending(address implementation);
    error NotAPatch(uint64 previous, uint64 version);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param genesisImplementation the first implementation, listed immediately (nobody uses the
    ///        registry before it exists, so there is nothing to protect with a delay yet).
    /// @param council_ the security council allowed to fast-track patch releases; address(0) = none.
    constructor(address owner_, address genesisImplementation, address council_) {
        if (owner_ == address(0)) revert ZeroAddress();
        council = council_;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        _list(genesisImplementation, uint64(block.timestamp), true);
    }

    function proposeRelease(address implementation) external onlyOwner {
        _list(implementation, uint64(block.timestamp + approvalDelay()), false);
    }

    /// @notice Time between proposing a release and vaults being able to run it.
    function approvalDelay() public view returns (uint256) {
        return EPKChains.isTestChain() ? TEST_APPROVAL_DELAY : APPROVAL_DELAY;
    }

    /// @notice Blocks future opt-ins to a release (vaults already running it are not touched). The owner
    ///         or the security council may revoke, e.g. a release proposed with a stolen owner key.
    function revokeRelease(address implementation) external {
        if (msg.sender != owner && (msg.sender != council || council == address(0))) revert NotOwnerOrCouncil();
        Release storage r = releases[implementation];
        if (r.version == 0) revert UnknownRelease(implementation);
        r.revoked = true;
        emit ReleaseRevoked(implementation, r.version);
    }

    // slither-disable-start timestamp
    // timestamp: the release window is 7 days; a few seconds of validator skew are irrelevant.
    /// @notice Security council only: make an already-proposed, not yet usable PATCH release (same major and
    ///         minor version as the release listed before it) usable now, skipping the public window.
    ///         Vaults still opt in themselves through their own upgrade wait, which guardians can veto.
    function fastTrack(address implementation) external {
        if (msg.sender != council || council == address(0)) revert NotCouncil();
        Release storage r = releases[implementation];
        if (r.version == 0) revert UnknownRelease(implementation);
        if (r.revoked || block.timestamp >= r.activeAt) revert NotPending(implementation);
        uint64 previous = previousVersionOf[implementation];
        if (r.version / 100 != previous / 100) revert NotAPatch(previous, r.version);
        r.activeAt = uint64(block.timestamp);
        isUrgent[implementation] = true;
        emit ReleaseFastTracked(implementation, r.version);
    }
    // slither-disable-end timestamp

    // slither-disable-start timestamp,incorrect-equality
    // timestamp: the approval delay is 7 days; a few seconds of validator skew are irrelevant.
    // incorrect-equality: the strict comparisons are intentional — `version != 0` is the "listed"
    // sentinel and `codehash ==` is the pin that must match exactly.
    /// @notice True if a vault may run / upgrade to `implementation` right now.
    function isApproved(address implementation) external view override returns (bool) {
        Release memory r = releases[implementation];
        return r.version != 0 && block.timestamp >= r.activeAt && !r.revoked
            && implementation.codehash == r.codehash;
    }
    // slither-disable-end timestamp,incorrect-equality

    function versionOf(address implementation) external view override returns (uint64) {
        return releases[implementation].version;
    }

    /// @notice Starts a two-step ownership transfer (the new owner must accept).
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // slither-disable-start timestamp
    // timestamp: false positive — only the "listed" sentinel (`version`) is compared; Slither taints
    // the whole Release struct because it also stores `activeAt`.
    function _list(address implementation, uint64 activeAt, bool genesis) internal {
        bytes memory code = implementation.code;
        if (code.length == 0) revert NoCode(implementation);
        // EIP-7702 delegated accounts (0xEF0100…) can change "their" code at any time
        if (code[0] == 0xEF) revert DelegatedCode(implementation);
        if (releases[implementation].version != 0) revert AlreadyListed(implementation);

        uint64 version = 0;
        try IVersionedVault(implementation).vaultVersion() returns (uint64 v) {
            version = v;
        } catch {
            revert NotAVault(implementation);
        }
        if (version <= latestVersion) revert VersionNotHigher(latestVersion, version);
        if (!genesis && version - latestVersion > MAX_VERSION_STEP) {
            revert VersionStepTooLarge(latestVersion, version);
        }

        bytes32 codehash = implementation.codehash;
        releases[implementation] =
            Release({version: version, activeAt: activeAt, revoked: false, codehash: codehash});
        previousVersionOf[implementation] = latestVersion;
        latestVersion = version;
        emit ReleaseProposed(implementation, version, activeAt, codehash);
    }
    // slither-disable-end timestamp
}
