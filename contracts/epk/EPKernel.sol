// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPolicyValidator} from "./IPolicyValidator.sol";

/// @title Eternal Permission Kernel (EPK) — v1.0.0
/// @notice Immutable core executor: capability-based execution with EIP-712 owner signatures.
/// @dev FROZEN CORE — no upgrades, no storage changes.
///      Future extensions must be implemented externally.
///      No upgrades, no new fields, no changes after deployment.
///      Any new features → only through Validators / Registry / SDK.

contract EPKernel {

    // ███████╗██████╗ ██╗  ██╗
    // ██╔════╝██╔══██╗██║ ██╔╝
    // █████╗  ██████╔╝█████╔╝
    // ██╔══╝  ██╔══██╗██╔═██╗
    // ███████╗██║  ██║██║  ██╗
    // ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝
    //
    // EPKernel v1.0.0 — FROZEN / IMMUTABLE CORE

    // --- EIP-712 domain (normative)
    string public constant EIP712_NAME = "Eternal Permission Kernel";
    string public constant EIP712_VERSION = "1";

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    address private immutable _CACHED_THIS;

    // Execute(policyId, target, value, keccak256(data), nonce, deadline)
    bytes32 private constant _EXECUTE_TYPEHASH = keccak256(
        "Execute(uint256 policyId,address target,uint256 value,bytes32 dataHash,uint256 nonce,uint256 deadline)"
    );

    // --- v1 policy model (normative)
    struct Policy {
        address owner; // policy exists iff owner != address(0)
        bool active; // quick revoke switch
        uint48 validUntil; // policy TTL (0 = no expiry)
        uint96 maxValuePerCall; // max native value per call
        address validator; // optional validator (0 = none)
    }

    // --- v1 agent permissions (normative)
    struct AgentPermission {
        bool allowed;
        uint40 validUntil; // agent TTL (0 = no expiry)
    }

    // --- storage (normative)
    mapping(uint256 => Policy) public policies;
    mapping(uint256 => uint256) public nonces;
    mapping(uint256 => mapping(address => AgentPermission)) public agentPermission;
    mapping(uint256 => mapping(bytes32 => bool)) public callAllowed; // callKey => allowed

    uint256 public nextPolicyId;

    // --- events
    event PolicyCreated(uint256 indexed policyId, address indexed owner);
    event PolicyUpdated(uint256 indexed policyId, uint48 validUntil, uint96 maxValuePerCall, address validator);
    event PolicyStatus(uint256 indexed policyId, bool active);
    event AgentSet(uint256 indexed policyId, address indexed agent, bool allowed, uint40 validUntil);
    event CallSet(uint256 indexed policyId, address indexed target, bytes4 indexed selector, bool allowed);
    event NonceBumped(uint256 indexed policyId, uint256 newNonce);

    /// @notice Audit event (normative minimum fields)
    event Executed(
        uint256 indexed policyId,
        address indexed owner,
        address indexed agent,
        address target,
        bytes4 selector,
        uint256 value
    );

    // --- errors
    error PolicyNotFound();
    error PolicyInactive();
    error DeadlineRequired();
    error Expired();
    error AgentNotAllowed();
    error AgentExpired();
    error CallNotAllowed();
    error ValueTooHigh();
    error MsgValueMismatch();
    error BadSignature();
    error NonceTooLow();
    error NotPolicyOwner();
    error ZeroAgent();
    error ZeroTarget();

    constructor() {
        _HASHED_NAME = keccak256(bytes(EIP712_NAME));
        _HASHED_VERSION = keccak256(bytes(EIP712_VERSION));
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_THIS = address(this);
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    // ---------------------------------------------------------------------
    // Policy management (utility layer; kernel remains immutable)
    // ---------------------------------------------------------------------

    function createPolicy(uint48 validUntil, uint96 maxValuePerCall, address validator)
        external
        returns (uint256 policyId)
    {
        policyId = nextPolicyId++;
        policies[policyId] = Policy({
            owner: msg.sender,
            active: true,
            validUntil: validUntil,
            maxValuePerCall: maxValuePerCall,
            validator: validator
        });

        emit PolicyCreated(policyId, msg.sender);
        emit PolicyUpdated(policyId, validUntil, maxValuePerCall, validator);
        emit PolicyStatus(policyId, true);
    }
    modifier onlyPolicyOwner(uint256 policyId) {
        address o = policies[policyId].owner;
        if (o == address(0)) revert PolicyNotFound();
        if (o != msg.sender) revert NotPolicyOwner();
        _;
    }

    /// @notice Panic switch (normative).
    function setPolicyActive(uint256 policyId, bool active) external onlyPolicyOwner(policyId) {
        policies[policyId].active = active;
        emit PolicyStatus(policyId, active);
    }

    function updatePolicy(uint256 policyId, uint48 validUntil, uint96 maxValuePerCall, address validator)
        external
        onlyPolicyOwner(policyId)
    {
        Policy storage p = policies[policyId];
        p.validUntil = validUntil;
        p.maxValuePerCall = maxValuePerCall;
        p.validator = validator;
        emit PolicyUpdated(policyId, validUntil, maxValuePerCall, validator);
    }

    function setAgent(uint256 policyId, address agent, bool allowed, uint40 validUntilAgent)
        external
        onlyPolicyOwner(policyId)
    {
        if (agent == address(0)) revert ZeroAgent();
        agentPermission[policyId][agent] = AgentPermission({allowed: allowed, validUntil: validUntilAgent});
        emit AgentSet(policyId, agent, allowed, validUntilAgent);
    }

    function setCall(uint256 policyId, address target, bytes4 selector, bool allowed)
        external
        onlyPolicyOwner(policyId)
    {
        if (target == address(0)) revert ZeroTarget();
        bytes32 callKey = keccak256(abi.encodePacked(target, selector));
        callAllowed[policyId][callKey] = allowed;
        emit CallSet(policyId, target, selector, allowed);
    }

    /// @notice Emergency nonce bump to invalidate queued signatures (normative).
    function emergencyNonceBump(uint256 policyId, uint256 newNonce) external onlyPolicyOwner(policyId) {
        uint256 current = nonces[policyId];
        if (newNonce <= current) revert NonceTooLow();
        nonces[policyId] = newNonce;
        emit NonceBumped(policyId, newNonce);
    }

    // ---------------------------------------------------------------------
    // Execution interface (normative order)
    // ---------------------------------------------------------------------

    function execute(
        uint256 policyId,
        address target,
        uint256 value,
        bytes calldata data,
        uint256 deadline,
        bytes calldata signature
    ) external payable returns (bytes memory out) {
        // 1) Policy exists & active
        Policy memory p = policies[policyId];
        if (p.owner == address(0)) revert PolicyNotFound();
        if (!p.active) revert PolicyInactive();

        // 2) Deadline required & fresh (prevents timeless sigs)
        if (deadline == 0) revert DeadlineRequired();
        if (deadline <= block.timestamp) revert Expired();

        // 3) Effective expiry (min(policyTTL, deadline))
        uint256 policyExpiry = (p.validUntil == 0) ? type(uint256).max : uint256(p.validUntil);
        uint256 effectiveExpiry = policyExpiry < deadline ? policyExpiry : deadline;
        if (block.timestamp > effectiveExpiry) revert Expired();

        // 4) Agent permission (with TTL)
        AgentPermission memory ap = agentPermission[policyId][msg.sender];
        if (!ap.allowed) revert AgentNotAllowed();
        if (ap.validUntil != 0 && block.timestamp > ap.validUntil) revert AgentExpired();

        // 5) Target + selector allowlist
        if (data.length < 4) revert CallNotAllowed();
        bytes4 selector = bytes4(data[:4]);
        bytes32 callKey = keccak256(abi.encodePacked(target, selector));
        if (!callAllowed[policyId][callKey]) revert CallNotAllowed();

        // 6) Value bound + no hidden value
        if (value > uint256(p.maxValuePerCall)) revert ValueTooHigh();
        if (msg.value != value) revert MsgValueMismatch();

        // 7) Nonce match (current nonce included in signature)
        uint256 nonce = nonces[policyId];

        // 8) EIP-712 signature check (owner only)
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(_EXECUTE_TYPEHASH, policyId, target, value, keccak256(data), nonce, deadline))
        );

        address signer = _recover(digest, signature);
        if (signer != p.owner) revert BadSignature();

        // 9) Optional validator (revert MUST bubble unchanged)
        if (p.validator != address(0)) {
            IPolicyValidator(p.validator).validate(policyId, p.owner, msg.sender, target, value, data);
        }

        // 10) Nonce increment then call
        nonces[policyId] = nonce + 1;

        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly { revert(add(ret, 0x20), mload(ret)) }
        }

        // 11) Audit event
        emit Executed(policyId, p.owner, msg.sender, target, selector, value);
        return ret;
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @notice Convenience for tests/SDK.
    function getTypedDataHash(
        uint256 policyId,
        address target,
        uint256 value,
        bytes32 dataHash,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(_EXECUTE_TYPEHASH, policyId, target, value, dataHash, nonce, deadline))
        );
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return
            keccak256(abi.encode(_EIP712_DOMAIN_TYPEHASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this)));
    }

    function _domainSeparatorV4() internal view returns (bytes32) {
        if (address(this) == _CACHED_THIS && block.chainid == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        }
        return _buildDomainSeparator();
    }

    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparatorV4(), structHash));
    }

    // Minimal ECDSA recover with low-s check.
    function _recover(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) revert BadSignature();

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }

        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert BadSignature();

        // secp256k1n/2
        bytes32 halfOrder = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;
        if (uint256(s) > uint256(halfOrder)) revert BadSignature();

        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert BadSignature();
        return signer;
    }

    receive() external payable {}
}