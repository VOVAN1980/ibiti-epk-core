// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

interface IVersionedVault {
    function vaultVersion() external view returns (uint64);
}

/// @title EPK Registry — catalogue of reviewed EPKVault implementations
/// @notice Lists the implementation versions that vaults MAY opt into. The registry cannot upgrade,
///         pause or touch any vault: every vault decides for itself (admin + timelock + guardian veto).
///         A vault's registry is fixed at creation and cannot be swapped.
///         A new release becomes usable only APPROVAL_DELAY after it is proposed, so the public can
///         inspect it first; a release can be revoked instantly (blocks future opt-ins only).
contract EPKRegistry {
    struct Release {
        uint64 version; // read from the implementation's own vaultVersion()
        uint64 activeAt; // 0 = unknown
        bool revoked;
        bytes32 codehash; // pinned at proposal time
    }

    uint256 public constant APPROVAL_DELAY = 7 days;
    /// @notice Largest version jump per release (one major version), so the version space cannot be
    ///         exhausted by a single malicious proposal.
    uint64 public constant MAX_VERSION_STEP = 10_000;

    address public owner;
    address public pendingOwner;
    uint64 public latestVersion;
    mapping(address => Release) public releases;

    event ReleaseProposed(address indexed implementation, uint64 version, uint64 activeAt, bytes32 codehash);
    event ReleaseRevoked(address indexed implementation, uint64 version);
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

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param genesisImplementation the first implementation, listed immediately (nobody uses the
    ///        registry before it exists, so there is nothing to protect with a delay yet).
    constructor(address owner_, address genesisImplementation) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        _list(genesisImplementation, uint64(block.timestamp), true);
    }

    function proposeRelease(address implementation) external onlyOwner {
        _list(implementation, uint64(block.timestamp + APPROVAL_DELAY), false);
    }

    function revokeRelease(address implementation) external onlyOwner {
        Release storage r = releases[implementation];
        if (r.activeAt == 0) revert UnknownRelease(implementation);
        r.revoked = true;
        emit ReleaseRevoked(implementation, r.version);
    }

    /// @notice True if a vault may run / upgrade to `implementation` right now.
    function isApproved(address implementation) external view returns (bool) {
        Release memory r = releases[implementation];
        return r.activeAt != 0 && block.timestamp >= r.activeAt && !r.revoked
            && implementation.codehash == r.codehash;
    }

    function versionOf(address implementation) external view returns (uint64) {
        return releases[implementation].version;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function _list(address implementation, uint64 activeAt, bool genesis) internal {
        if (implementation.code.length == 0) revert NoCode(implementation);
        // EIP-7702 delegated accounts (0xEF0100…) can change "their" code at any time
        uint8 first;
        assembly {
            let ptr := mload(0x40)
            extcodecopy(implementation, ptr, 0, 1)
            first := byte(0, mload(ptr))
        }
        if (first == 0xEF) revert DelegatedCode(implementation);
        if (releases[implementation].activeAt != 0) revert AlreadyListed(implementation);

        uint64 version;
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
        latestVersion = version;
        emit ReleaseProposed(implementation, version, activeAt, codehash);
    }
}
