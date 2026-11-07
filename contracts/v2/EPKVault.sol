// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IPolicyValidator} from "../epk/IPolicyValidator.sol";
import {IEPKGuard} from "./guards/IEPKGuard.sol";
import {IEPKRegistry, IVersionedVault} from "./IEPK.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

/// @title EPK Vault — v2 (one protected vault per customer)
/// @notice Holds a customer's funds and lets agents act on them only within on-chain rules that a
///         compromised operator key, server or AI agent cannot lift:
///         - isolation: every customer has their own vault; calls are made from the vault itself,
///           so nobody else's policy can ever reach these funds (fixes the v1 shared-executor issue);
///         - role separation: operator signer / admin / guardians (stop only) / recovery key;
///         - outflow limits per asset, measured on real balance changes (token bucket);
///         - destination allowlist for transfers, approvals and native value;
///         - token allowances never outlive the signed batch that created them;
///         - optional independent co-signer for large outflows;
///         - asymmetric rule changes: tighten instantly, loosen only through a timelock that
///           guardians can veto;
///         - one-call kill switch (`panic`) that pauses and invalidates every policy and pending change;
///         - opt-in upgrades: the vault keeps its address and funds; only its own admin can move it to
///           a newer registry-approved implementation, through a 2x-delay timelock guardians can veto.
/// @dev Threat model: the operator signer, the agent and the co-signer may all be compromised at the
///      same time. Damage is then bounded by `maxPerWindow` per tracked asset and by the destination
///      allowlist. See docs/SPEC_v2.md, docs/SECURITY_REVIEW_v2.md, docs/EPK_V2_UPGRADE_ARCHITECTURE.md.
///      Deployed behind an ERC-1967 proxy. STORAGE LAYOUT IS APPEND-ONLY across versions
///      (snapshot: docs/storage-layout/EPKVault-2.0.0.txt).
contract EPKVault is Initializable, UUPSUpgradeable, IVersionedVault {
    // ---------------------------------------------------------------------
    // Types & constants
    // ---------------------------------------------------------------------

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    string internal constant EIP712_NAME = "EPK Vault";
    string internal constant EIP712_VERSION = "2";

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _CALL_TYPEHASH = keccak256("Call(address target,uint256 value,bytes data)");
    bytes32 private constant _EXECUTE_TYPEHASH = keccak256(
        "Execute(uint256 policyId,address agent,Call[] calls,uint256 nonce,uint256 deadline)"
        "Call(address target,uint256 value,bytes data)"
    );
    bytes32 private constant _COSIGN_TYPEHASH = keccak256("CoSign(bytes32 executeDigest)");

    /// @notice Asset key used for the chain's native coin.
    address public constant NATIVE = address(0);
    /// @notice Selector key used in the call allowlist for a plain native transfer (empty calldata).
    bytes4 internal constant NATIVE_TRANSFER_SELECTOR = bytes4(0);

    uint256 internal constant MIN_DELAY = 1 hours;
    uint256 internal constant MAX_DELAY = 30 days;
    /// @notice A ready operation must be executed within this period, otherwise it goes stale.
    uint256 public constant GRACE_PERIOD = 14 days;
    uint256 internal constant MAX_TRACKED_ASSETS = 16;
    uint256 internal constant MAX_CALLS = 16;
    uint256 internal constant SESSION_ID_BASE = 1 << 128;
    /// @notice Guardians required before the vault can go live (admin is never a guardian).
    uint256 internal constant MIN_GUARDIANS = 2;
    /// @notice An upgrade always waits at least this long, whatever the vault delay is.
    uint256 public constant UPGRADE_DELAY_FLOOR = 2 days;

    bytes4 private constant _ERC1271_MAGIC = 0x1626ba7e;
    bytes4 private constant _SEL_TRANSFER = 0xa9059cbb; // transfer(address,uint256)
    bytes4 private constant _SEL_TRANSFER_FROM = 0x23b872dd; // transferFrom(address,address,uint256)
    bytes4 private constant _SEL_APPROVE = 0x095ea7b3; // approve(address,uint256)
    bytes4 private constant _SEL_INCREASE_ALLOWANCE = 0x39509351; // increaseAllowance(address,uint256)
    bytes4 private constant _SEL_SET_APPROVAL_FOR_ALL = 0xa22cb465; // setApprovalForAll(address,bool)

    struct Policy {
        address signer; // operator key (EOA or ERC-1271 contract); policy exists iff signer != 0
        bool active;
        uint48 validUntil; // 0 = no expiry
        uint64 epoch; // policy is valid only while epoch == vault epoch
        uint128 maxValuePerCall; // native value cap per call
        address validator; // optional extra rules (0 = none)
        uint64 envelope; // sessions: envelopeId + 1 (calls and budgets come from that envelope); 0 = policy
        uint32 generation; // sessions: envelope generation at opening (switching the envelope off ends it)
    }

    struct AgentPermission {
        bool allowed;
        uint40 validUntil; // 0 = no expiry
    }

    struct Asset {
        bool tracked;
        uint32 window; // seconds for the bucket to refill from empty to full
        uint64 lastUpdate;
        uint128 maxPerWindow; // bucket capacity
        uint128 available; // bucket level at lastUpdate
        uint128 coSignAbove; // one execute() moving more than this needs the co-signer
    }

    struct Operation {
        uint64 readyAt;
        uint64 epoch;
        bool epochExempt; // survives panic / revokeAll
        bool adminCannotCancel; // recovery operations
        address shielded; // this guardian cannot cancel the operation (it is the one being removed)
        uint64 version; // vaultVersion() at scheduling; ordinary operations go stale after an upgrade
    }

    /// @notice Session template ("envelope"): set through the timelock, narrowing is instant and applies
    ///         to every open session of the envelope at once. Calls and per-asset budgets of the
    ///         envelope live in `envelopeCallAllowed` / `envelopeBudgetCap`.
    struct Envelope {
        bool active;
        uint48 maxTtl; // longest session that may be opened
        uint128 maxValuePerCall; // native value cap of every session (applies live)
        uint32 generation; // bumped on every switch-off: sessions of an older generation stay dead
    }

    /// @notice A session's own spending bucket for one asset (capacity = envelope budget cap).
    struct Budget {
        uint128 available;
        uint64 lastUpdate; // 0 = untouched (full)
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    address public admin;
    address public recovery;
    mapping(address => bool) public isGuardian;
    uint256 public guardianCount;
    address public coSigner;
    address public registry;

    uint256 public delay;
    bool public paused;
    bool public setupDone;
    uint64 public epoch;
    bool private _locked;

    mapping(address => bool) public isDestination;
    mapping(address => Asset) public assets;
    address[] private _trackedAssets;

    mapping(uint256 => Policy) public policies;
    uint256 public nextPolicyId;
    mapping(uint256 => uint256) public nonces;
    mapping(uint256 => mapping(address => AgentPermission)) public agentPermission;
    mapping(uint256 => mapping(bytes32 => bool)) public callAllowed;

    mapping(bytes32 => Operation) internal operations; // watch OperationScheduled / Executed / Cancelled events

    // Agent sessions
    address public sessionManager;
    mapping(uint256 => Envelope) public envelopes;
    mapping(uint256 => mapping(bytes32 => bool)) public envelopeCallAllowed;
    mapping(uint256 => mapping(address => uint128)) public envelopeBudgetCap;
    mapping(uint256 => mapping(address => Budget)) public policyBudgets;

    /// @notice Sessions get ids from SESSION_ID_BASE upward, so opening sessions never shifts the ids
    ///         that timelocked `createPolicy` operations will return.
    uint256 public nextSessionId;

    // Future versions: append new state variables BELOW this line only.

    // 2.1.0: guard for every session of an envelope (IEPKGuard; 0 = none: sessions may then make only the
    //        calls the vault inspects itself — token transfers / approvals and plain native transfers).
    mapping(uint256 => address) public envelopeGuard;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event RecoverySet(address indexed recovery);
    event RegistrySet(address indexed registry);
    event SessionManagerSet(address indexed manager);
    event EnvelopeSet(uint256 indexed envelopeId, bool active, uint48 maxTtl, uint128 maxValuePerCall);
    event EnvelopeCallSet(uint256 indexed envelopeId, address indexed target, bytes4 indexed selector, bool allowed);
    event EnvelopeBudgetCapSet(uint256 indexed envelopeId, address indexed asset, uint128 cap);
    event EnvelopeGuardSet(uint256 indexed envelopeId, address indexed guard);
    event SessionOpened(
        uint256 indexed policyId, uint256 indexed envelopeId, address signer, address indexed agent, uint48 validUntil
    );
    event GuardianSet(address indexed guardian, bool enabled);
    event CoSignerSet(address indexed coSigner);
    event DelaySet(uint256 delay);
    event SetupFinalized();
    event Paused(address indexed by);
    event Unpaused();
    event EpochBumped(uint64 newEpoch, address indexed by);

    event OperationScheduled(bytes32 indexed id, bytes data, bytes32 salt, uint64 readyAt, address indexed by);
    event OperationExecuted(bytes32 indexed id);
    event OperationCancelled(bytes32 indexed id, address indexed by);

    event PolicyCreated(uint256 indexed policyId, address indexed signer);
    event PolicyUpdated(
        uint256 indexed policyId, address indexed signer, uint48 validUntil, uint128 maxValuePerCall, address validator
    );
    event PolicyStatus(uint256 indexed policyId, bool active);
    event AgentSet(uint256 indexed policyId, address indexed agent, bool allowed, uint40 validUntil);
    event CallSet(uint256 indexed policyId, address indexed target, bytes4 indexed selector, bool allowed);
    event NonceBumped(uint256 indexed policyId, uint256 newNonce);

    event DestinationSet(address indexed destination, bool allowed);
    event AssetSet(address indexed token, uint128 maxPerWindow, uint32 window, uint128 coSignAbove);
    event AssetUntracked(address indexed token);
    event Outflow(address indexed token, uint256 amount, uint256 availableAfter);

    event Executed(uint256 indexed policyId, address indexed signer, address indexed agent, uint256 nonce, uint256 calls);
    event CallExecuted(uint256 indexed policyId, address indexed target, bytes4 selector, uint256 value);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotAdmin();
    error NotRecovery();
    error NotAdminOrGuardian();
    error NotAdminOrRecovery();
    error NotTimelocked();
    error Reentrancy();
    error ZeroAddress();
    error BadDelay();
    error BadRole(address account);
    error TooFewGuardians();
    error SetupAlreadyFinished();
    error SetupNotFinished();
    error IsPaused();
    error IsSession();
    error BadOperation();
    error OperationExists();
    error UnknownOperation();
    error OperationNotReady();
    error StaleOperation();
    error CannotCancel();
    error PolicyNotFound();
    error PolicyInactive();
    error DeadlineRequired();
    error Expired();
    error AgentNotAllowed();
    error AgentExpired();
    error BadTarget();
    error CallNotAllowed();
    error ValueTooHigh();
    error BadCalldata();
    error BadSignature();
    error NonceTooLow();
    error DestinationNotAllowed(address destination);
    error UntrackedAsset(address token);
    error TooManyAssets();
    error NotTighter();
    error ForbiddenApproval();
    error AllowanceLeft(address token, address spender);
    error TokenCallFailed(address token);
    error LimitExceeded(address token, uint256 amount, uint256 available);
    error CoSignatureRequired(address token, uint256 amount);
    error ImplementationNotApproved(address implementation);
    error NotSessionManager();
    error OutsideEnvelope();
    error BudgetExceeded(address token, uint256 amount, uint256 available);
    error NotNewerVersion(uint64 current, uint64 proposed);
    error GuardRequired();

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    // Modifiers delegate to internal functions so their code exists once (bytecode size, EIP-170).

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    modifier onlyAdminOrGuardian() {
        _onlyAdminOrGuardian();
        _;
    }

    /// @dev Loosening changes: only through the timelock (the vault calling itself), or directly by
    ///      the admin while the initial setup is still open (no funds can move before setup ends).
    modifier onlyTimelocked() {
        _onlyTimelocked();
        _;
    }

    function _onlyAdmin() internal view {
        if (msg.sender != admin) revert NotAdmin();
    }

    function _onlyAdminOrGuardian() internal view {
        if (msg.sender != admin && !isGuardian[msg.sender]) revert NotAdminOrGuardian();
    }

    function _onlyTimelocked() internal view {
        if (msg.sender != address(this) && (setupDone || msg.sender != admin)) revert NotTimelocked();
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @dev The implementation itself can never be initialized; only proxies can.
    constructor() {
        _disableInitializers();
    }

    /// @param recovery_ optional cold key that can replace a lost or compromised admin (0 = none).
    /// @param registry_ catalogue of approved implementations this vault may opt into.
    function initialize(
        address admin_,
        address[] calldata guardians_,
        uint256 delay_,
        address recovery_,
        address registry_
    ) external initializer {
        if (admin_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        if (admin_ == address(this)) revert BadRole(admin_);
        if (delay_ < MIN_DELAY || delay_ > MAX_DELAY) revert BadDelay();

        admin = admin_;
        delay = delay_;
        emit AdminChanged(address(0), admin_);
        emit DelaySet(delay_);

        for (uint256 i = 0; i < guardians_.length; i++) {
            address g = guardians_[i];
            if (g == address(0)) revert ZeroAddress();
            if (g == admin_ || g == recovery_ || g == address(this) || isGuardian[g]) revert BadRole(g);
            isGuardian[g] = true;
            emit GuardianSet(g, true);
        }
        guardianCount = guardians_.length;

        if (recovery_ == admin_ || recovery_ == address(this)) revert BadRole(recovery_);
        recovery = recovery_;
        emit RecoverySet(recovery_);

        registry = registry_;
        emit RegistrySet(registry_);
    }

    /// @notice Implementation version: major * 10_000 + minor * 100 + patch.
    function vaultVersion() public pure virtual override returns (uint64) {
        return 20_100; // 2.1.0
    }

    receive() external payable {}

    // ---------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------

    /// @notice Ends the initial setup. From now on every loosening change goes through the timelock,
    ///         and only now can funds move.
    function finalizeSetup() external onlyAdmin {
        if (setupDone) revert SetupAlreadyFinished();
        if (guardianCount < MIN_GUARDIANS) revert TooFewGuardians();
        setupDone = true;
        emit SetupFinalized();
    }

    // ---------------------------------------------------------------------
    // Timelock (loosening changes)
    // ---------------------------------------------------------------------

    function hashOperation(bytes memory data, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(data, salt));
    }

    /// @notice Schedules a call to one of this vault's `onlyTimelocked` functions.
    /// @dev Removing or replacing a guardian is shielded: that guardian cannot cancel it and a panic
    ///      does not invalidate it, so a single rogue guardian cannot freeze the vault forever.
    function schedule(bytes calldata data, bytes32 salt) external onlyAdmin returns (bytes32 id) {
        if (data.length < 4) revert BadOperation();
        bytes4 sel = bytes4(data[:4]);
        // upgrades and migrations only through scheduleUpgrade
        if (sel == UUPSUpgradeable.upgradeToAndCall.selector || sel == EPKVault.migrate.selector) {
            revert BadOperation();
        }
        address shielded = address(0);
        if (sel == this.setGuardian.selector) {
            (address g, bool enabled) = abi.decode(data[4:], (address, bool));
            if (!enabled) shielded = g;
        } else if (sel == this.replaceGuardian.selector) {
            (address g,) = abi.decode(data[4:], (address, address));
            shielded = g;
        }
        id = _schedule(data, salt, delay, shielded != address(0), false, shielded);
    }

    /// @notice Recovery key: replace a lost or compromised admin. Takes twice the normal delay,
    ///         survives panic, cannot be cancelled by the admin; any guardian can still veto it.
    function recoverAdmin(address newAdmin, bytes32 salt) external returns (bytes32 id) {
        if (msg.sender != recovery || recovery == address(0)) revert NotRecovery();
        id = _schedule(abi.encodeCall(this.setAdmin, (newAdmin)), salt, delay * 2, true, true, address(0));
    }

    /// @notice Opt this vault into a newer, registry-approved implementation. Address, funds and
    ///         settings stay. Takes max(2 × delay, UPGRADE_DELAY_FLOOR); any guardian (or the recovery
    ///         key) can veto; a panic cancels it. The new release's `migrate()` always runs with it;
    ///         no other code can be attached to an upgrade.
    function scheduleUpgrade(address newImplementation, bytes32 salt) external onlyAdmin returns (bytes32 id) {
        _requireUpgradeAllowed(newImplementation);
        uint256 wait = delay * 2;
        if (wait < UPGRADE_DELAY_FLOOR) wait = UPGRADE_DELAY_FLOOR;
        id = _schedule(_upgradeCall(newImplementation), salt, wait, false, false, address(0));
    }

    /// @notice The exact operation data `scheduleUpgrade` schedules (pass it to `executeScheduled`).
    function upgradeOperationData(address newImplementation) external pure returns (bytes memory) {
        return _upgradeCall(newImplementation);
    }

    function _upgradeCall(address newImplementation) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            UUPSUpgradeable.upgradeToAndCall.selector,
            newImplementation,
            abi.encodeWithSelector(EPKVault.migrate.selector)
        );
    }

    // slither-disable-start timestamp,low-level-calls
    // timestamp: compares a readiness time hours/days away; a few seconds of validator skew are irrelevant.
    // low-level-calls: the call targets the vault itself (only its onlyTimelocked functions accept it);
    // its result is checked and bubbled with OpenZeppelin Address.verifyCallResult.
    /// @notice Admin executes any ready operation; the recovery key only its own recovery operations.
    function executeScheduled(bytes calldata data, bytes32 salt) external nonReentrant {
        bytes32 id = hashOperation(data, salt);
        Operation memory op = operations[id];
        if (msg.sender != admin) {
            if (msg.sender != recovery) revert NotAdminOrRecovery();
            if (_exists(op) && !op.adminCannotCancel) revert NotAdminOrRecovery();
        }
        if (!_exists(op)) revert UnknownOperation();
        if (!_isLive(op)) revert StaleOperation();
        if (block.timestamp < op.readyAt) revert OperationNotReady();
        delete operations[id];

        (bool ok, bytes memory ret) = address(this).call(data);
        ret = Address.verifyCallResult(ok, ret);
        emit OperationExecuted(id);
    }
    // slither-disable-end timestamp,low-level-calls

    // slither-disable-start timestamp
    // timestamp: false positive — only the existence sentinel (`version`) of the stored operation is
    // compared; Slither taints the whole struct because it also holds `readyAt`.
    /// @notice Admin, any guardian or the recovery key can veto a pending change (see shielding rules).
    ///         The recovery key's veto matters when the admin is compromised and a guardian is absent.
    function cancel(bytes32 id) external {
        if (msg.sender != admin && !isGuardian[msg.sender] && (msg.sender != recovery || recovery == address(0))) {
            revert NotAdminOrGuardian();
        }
        Operation memory op = operations[id];
        if (!_exists(op)) revert UnknownOperation();
        if (msg.sender == op.shielded || (msg.sender == admin && op.adminCannotCancel)) revert CannotCancel();
        delete operations[id];
        emit OperationCancelled(id, msg.sender);
    }
    // slither-disable-end timestamp

    // ---------------------------------------------------------------------
    // Tightening (instant, admin or any guardian; none of these can move funds)
    // ---------------------------------------------------------------------

    function pause() external onlyAdminOrGuardian {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Invalidates every policy and every pending (non-shielded) operation at once.
    function revokeAll() external onlyAdminOrGuardian {
        _bumpEpoch();
    }

    /// @notice The big red button: pause + revokeAll.
    function panic() external onlyAdminOrGuardian {
        paused = true;
        emit Paused(msg.sender);
        _bumpEpoch();
    }

    /// @notice Deactivates a policy (or closes a session) and invalidates any signature already queued
    ///         for it. Admin, any guardian or the session manager.
    function revokePolicy(uint256 policyId) external {
        // the session manager may only close sessions, never ordinary policies
        if (msg.sender != admin && !isGuardian[msg.sender]) {
            if (msg.sender != sessionManager || policies[policyId].envelope == 0) revert NotAdminOrGuardian();
        }
        _requirePolicy(policyId);
        policies[policyId].active = false;
        uint256 n = nonces[policyId] + 1;
        nonces[policyId] = n;
        emit PolicyStatus(policyId, false);
        emit NonceBumped(policyId, n);
    }

    function revokeAgent(uint256 policyId, address agent) external onlyAdminOrGuardian {
        _requirePolicy(policyId);
        delete agentPermission[policyId][agent];
        emit AgentSet(policyId, agent, false, 0);
    }

    /// @dev Sessions use their envelope's calls: narrow the envelope (or revoke the session) instead.
    function disallowCall(uint256 policyId, address target, bytes4 selector) external onlyAdminOrGuardian {
        _requireOrdinaryPolicy(policyId);
        callAllowed[policyId][_callKey(target, selector)] = false;
        emit CallSet(policyId, target, selector, false);
    }

    function bumpNonce(uint256 policyId, uint256 newNonce) external onlyAdminOrGuardian {
        _requirePolicy(policyId);
        if (newNonce <= nonces[policyId] || newNonce == type(uint256).max) revert NonceTooLow();
        nonces[policyId] = newNonce;
        emit NonceBumped(policyId, newNonce);
    }

    function removeDestination(address destination) external onlyAdminOrGuardian {
        isDestination[destination] = false;
        emit DestinationSet(destination, false);
    }

    // slither-disable-start timestamp
    // timestamp: refreshes the limit's refill clock (hours/days granularity).
    /// @notice Lower an asset's limits instantly. Both values must not increase.
    function lowerAssetLimit(address token, uint128 newMaxPerWindow, uint128 newCoSignAbove)
        external
        onlyAdminOrGuardian
    {
        Asset storage a = assets[token];
        if (!a.tracked) revert UntrackedAsset(token);
        if (newMaxPerWindow > a.maxPerWindow || newCoSignAbove > a.coSignAbove) revert NotTighter();
        uint256 avail = _available(a);
        a.available = uint128(avail < newMaxPerWindow ? avail : newMaxPerWindow);
        a.lastUpdate = uint64(block.timestamp);
        a.maxPerWindow = newMaxPerWindow;
        a.coSignAbove = newCoSignAbove;
        emit AssetSet(token, newMaxPerWindow, a.window, newCoSignAbove);
    }
    // slither-disable-end timestamp

    // ---------------------------------------------------------------------
    // Loosening (timelocked; or admin during setup)
    // ---------------------------------------------------------------------

    function unpause() external onlyTimelocked {
        paused = false;
        emit Unpaused();
    }

    function createPolicy(address signer, uint48 validUntil, uint128 maxValuePerCall, address validator)
        external
        onlyTimelocked
        returns (uint256 policyId)
    {
        if (signer == address(0)) revert ZeroAddress();
        if (signer == address(this) || validator == address(this)) revert BadRole(address(this));
        policyId = nextPolicyId++;
        policies[policyId] = Policy({
            signer: signer,
            active: true,
            validUntil: validUntil,
            epoch: epoch,
            maxValuePerCall: maxValuePerCall,
            validator: validator,
            envelope: 0,
            generation: 0
        });
        emit PolicyCreated(policyId, signer);
        emit PolicyUpdated(policyId, signer, validUntil, maxValuePerCall, validator);
        emit PolicyStatus(policyId, true);
    }

    function updatePolicy(
        uint256 policyId,
        address signer,
        uint48 validUntil,
        uint128 maxValuePerCall,
        address validator
    ) external onlyTimelocked {
        _requireOrdinaryPolicy(policyId);
        if (signer == address(0)) revert ZeroAddress();
        if (signer == address(this) || validator == address(this)) revert BadRole(address(this));
        Policy storage p = policies[policyId];
        p.signer = signer;
        p.validUntil = validUntil;
        p.maxValuePerCall = maxValuePerCall;
        p.validator = validator;
        emit PolicyUpdated(policyId, signer, validUntil, maxValuePerCall, validator);
    }

    // ---------------------------------------------------------------------
    // Agent sessions: instant, bounded delegation inside a pre-approved envelope
    // ---------------------------------------------------------------------

    /// @dev Loosening changes need the timelock (or the admin during setup); tightening ones may be done
    ///      instantly by the admin, any guardian, or the vault itself through an executed operation.
    function _checkChange(bool loosening) internal view {
        if (loosening) {
            _onlyTimelocked();
        } else if (msg.sender != admin && msg.sender != address(this) && !isGuardian[msg.sender]) {
            revert NotAdminOrGuardian();
        }
    }

    /// @dev Sessions are governed by their envelope; per-policy settings never apply to them.
    function _requireOrdinaryPolicy(uint256 policyId) internal view {
        _requirePolicy(policyId);
        if (policies[policyId].envelope != 0) revert IsSession();
    }

    /// @dev The session manager is a separate hot key: never the admin, a guardian or the recovery key.
    function _isSessionManager(address account) internal view returns (bool) {
        return account != address(0) && account == sessionManager;
    }

    /// @notice Hot key (e.g. the operator's backend) that alone may open sessions inside envelopes, and
    ///         may close them. Setting one is timelocked; removing it (address(0)) is instant.
    function setSessionManager(address manager) external {
        _checkChange(manager != address(0));
        if (
            manager != address(0)
                && (manager == address(this) || manager == admin || manager == recovery || isGuardian[manager])
        ) revert BadRole(manager);
        sessionManager = manager;
        emit SessionManagerSet(manager);
    }

    /// @notice Outer bounds for sessions. Widening or (re)activating is timelocked; narrowing is instant.
    ///         The value cap applies live to open sessions; `maxTtl` limits sessions opened from now on.
    ///         Switching an envelope off ends all its sessions for good (a later re-activation does not
    ///         revive them).
    function setEnvelope(uint256 envelopeId, bool active, uint48 maxTtl, uint128 maxValuePerCall) external {
        Envelope memory old = envelopes[envelopeId];
        _checkChange(active && (!old.active || maxTtl > old.maxTtl || maxValuePerCall > old.maxValuePerCall));
        uint32 generation = old.generation;
        if (old.active && !active) generation++;
        envelopes[envelopeId] =
            Envelope({active: active, maxTtl: maxTtl, maxValuePerCall: maxValuePerCall, generation: generation});
        emit EnvelopeSet(envelopeId, active, maxTtl, maxValuePerCall);
    }

    /// @notice Guard (IEPKGuard) for every session of the envelope, applied live to open sessions.
    ///         Every change is timelocked: removing a guard drops its checks, and adding one to an
    ///         unguarded envelope unlocks calls the vault cannot inspect (see `_checkCalls`), so a
    ///         permissive guard installed with a stolen guardian key would be a hidden loosening.
    function setEnvelopeGuard(uint256 envelopeId, address guard) external onlyTimelocked {
        if (guard == address(this)) revert BadRole(guard);
        envelopeGuard[envelopeId] = guard;
        emit EnvelopeGuardSet(envelopeId, guard);
    }

    /// @notice A call sessions of this envelope may be given. Allowing is timelocked; removing is instant.
    function setEnvelopeCall(uint256 envelopeId, address target, bytes4 selector, bool allowed) external {
        _checkChange(allowed);
        if (target == address(0) || target == address(this)) revert BadTarget();
        envelopeCallAllowed[envelopeId][_callKey(target, selector)] = allowed;
        emit EnvelopeCallSet(envelopeId, target, selector, allowed);
    }

    /// @notice Per-window budget of `asset` that EACH session of this envelope gets (0 = sessions cannot
    ///         move this asset). Raising is timelocked; lowering is instant and applies to open sessions.
    function setEnvelopeBudgetCap(uint256 envelopeId, address asset, uint128 cap) external {
        _checkChange(cap > envelopeBudgetCap[envelopeId][asset]);
        if (cap != 0 && !assets[asset].tracked) revert UntrackedAsset(asset);
        envelopeBudgetCap[envelopeId][asset] = cap;
        emit EnvelopeBudgetCapSet(envelopeId, asset, cap);
    }

    // slither-disable-start timestamp
    // timestamp: checks that the requested expiry lies within the envelope's max TTL (seconds-to-days).
    /// @notice Open an agent session instantly (admin or session manager), inside an active envelope.
    ///         The session may make the envelope's calls, with its own budget per asset, until
    ///         `validUntil`; it dies with `panic`/`revokeAll` and can be closed with `revokePolicy`.
    /// @param signer session key that signs batches (can be the agent's own key)
    /// @param agent the only address allowed to submit the session's batches
    /// @param validUntil absolute expiry; must be in the future and at most `maxTtl` from now
    function openSession(uint256 envelopeId, address signer, address agent, uint48 validUntil)
        external
        returns (uint256 policyId)
    {
        // only the dedicated hot key: the admin key alone can never move funds instantly
        if (!_isSessionManager(msg.sender)) revert NotSessionManager();
        if (!setupDone) revert SetupNotFinished();
        if (paused) revert IsPaused();
        Envelope memory env = envelopes[envelopeId];
        if (
            envelopeId >= type(uint64).max || !env.active || validUntil <= block.timestamp
                || validUntil > block.timestamp + env.maxTtl
        ) revert OutsideEnvelope();
        if (signer == address(0) || agent == address(0)) revert ZeroAddress();
        if (signer == address(this)) revert BadRole(signer);

        policyId = SESSION_ID_BASE + nextSessionId++;
        policies[policyId] = Policy({
            signer: signer,
            active: true,
            validUntil: validUntil,
            epoch: epoch,
            maxValuePerCall: env.maxValuePerCall,
            validator: address(0),
            envelope: uint64(envelopeId) + 1,
            generation: env.generation
        });
        agentPermission[policyId][agent] = AgentPermission({allowed: true, validUntil: uint40(validUntil)});
        emit SessionOpened(policyId, envelopeId, signer, agent, validUntil);
    }
    // slither-disable-end timestamp

    function setPolicyActive(uint256 policyId, bool active) external onlyTimelocked {
        _requireOrdinaryPolicy(policyId);
        policies[policyId].active = active;
        emit PolicyStatus(policyId, active);
    }

    function setAgent(uint256 policyId, address agent, bool allowed, uint40 validUntil) external onlyTimelocked {
        _requireOrdinaryPolicy(policyId);
        if (agent == address(0)) revert ZeroAddress();
        agentPermission[policyId][agent] = AgentPermission({allowed: allowed, validUntil: validUntil});
        emit AgentSet(policyId, agent, allowed, validUntil);
    }

    function setCall(uint256 policyId, address target, bytes4 selector, bool allowed) external onlyTimelocked {
        _requireOrdinaryPolicy(policyId);
        if (target == address(0) || target == address(this)) revert BadTarget();
        callAllowed[policyId][_callKey(target, selector)] = allowed;
        emit CallSet(policyId, target, selector, allowed);
    }

    function addDestination(address destination) external onlyTimelocked {
        if (destination == address(0) || destination == address(this)) revert BadTarget();
        isDestination[destination] = true;
        emit DestinationSet(destination, true);
    }

    // slither-disable-start timestamp
    // timestamp: refreshes the limit's refill clock (hours/days granularity).
    /// @notice Track an asset and set its outflow limits (use NATIVE for the native coin).
    /// @dev An asset added after setup starts with an empty bucket, so untrack + re-add cannot be
    ///      used to refill a limit early.
    function setAsset(address token, uint128 maxPerWindow, uint32 window, uint128 coSignAbove)
        external
        onlyTimelocked
    {
        if (window == 0 || token == address(this)) revert BadOperation();
        Asset storage a = assets[token];
        if (!a.tracked) {
            if (_trackedAssets.length >= MAX_TRACKED_ASSETS) revert TooManyAssets();
            a.tracked = true;
            _trackedAssets.push(token);
            a.available = setupDone ? 0 : maxPerWindow;
        } else {
            uint256 avail = _available(a);
            a.available = uint128(avail < maxPerWindow ? avail : maxPerWindow);
        }
        a.lastUpdate = uint64(block.timestamp);
        a.maxPerWindow = maxPerWindow;
        a.window = window;
        a.coSignAbove = coSignAbove;
        emit AssetSet(token, maxPerWindow, window, coSignAbove);
    }
    // slither-disable-end timestamp

    function untrackAsset(address token) external onlyTimelocked {
        if (!assets[token].tracked) revert UntrackedAsset(token);
        delete assets[token];
        uint256 last = _trackedAssets.length - 1;
        uint256 index = last;
        for (uint256 i = 0; i < last; i++) {
            if (_trackedAssets[i] == token) {
                index = i;
                break;
            }
        }
        _trackedAssets[index] = _trackedAssets[last];
        _trackedAssets.pop();
        emit AssetUntracked(token);
    }

    function setCoSigner(address newCoSigner) external onlyTimelocked {
        if (newCoSigner == address(this)) revert BadRole(newCoSigner);
        coSigner = newCoSigner;
        emit CoSignerSet(newCoSigner);
    }

    function setGuardian(address guardian, bool enabled) external onlyTimelocked {
        if (guardian == address(0)) revert ZeroAddress();
        if (isGuardian[guardian] == enabled) return;
        if (enabled) {
            if (guardian == admin || guardian == recovery || guardian == address(this) || _isSessionManager(guardian)) {
                revert BadRole(guardian);
            }
            isGuardian[guardian] = true;
            guardianCount++;
        } else {
            if (setupDone && guardianCount <= MIN_GUARDIANS) revert TooFewGuardians();
            isGuardian[guardian] = false;
            guardianCount--;
        }
        emit GuardianSet(guardian, enabled);
    }

    /// @notice Swap one guardian for another (keeps the guardian count).
    function replaceGuardian(address oldGuardian, address newGuardian) external onlyTimelocked {
        if (!isGuardian[oldGuardian]) revert BadRole(oldGuardian);
        if (
            newGuardian == address(0) || isGuardian[newGuardian] || newGuardian == admin || newGuardian == recovery
                || newGuardian == address(this) || _isSessionManager(newGuardian)
        ) revert BadRole(newGuardian);
        isGuardian[oldGuardian] = false;
        isGuardian[newGuardian] = true;
        emit GuardianSet(oldGuardian, false);
        emit GuardianSet(newGuardian, true);
    }

    function setDelay(uint256 newDelay) external onlyTimelocked {
        if (newDelay < MIN_DELAY || newDelay > MAX_DELAY) revert BadDelay();
        delay = newDelay;
        emit DelaySet(newDelay);
    }

    function setAdmin(address newAdmin) external onlyTimelocked {
        if (newAdmin == address(0)) revert ZeroAddress();
        if (newAdmin == address(this) || isGuardian[newAdmin] || newAdmin == recovery || _isSessionManager(newAdmin)) {
            revert BadRole(newAdmin);
        }
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice One-time migration of a release. Runs only inside an upgrade (the vault calling itself).
    /// @dev Not overridable: it enforces the caller and captures the version the vault is migrating
    ///      FROM before any `reinitializer(n)` updates it, then hands over to `_migrate`.
    function migrate() external {
        if (msg.sender != address(this)) revert NotTimelocked();
        _migrate(_getInitializedVersion());
    }

    /// @dev Every release overrides this as `internal override reinitializer(n)` and runs every step
    ///      that `from` has not reached yet (vaults may skip releases). 2.0.0 is the first release,
    ///      so nothing can upgrade *to* it and this default refuses.
    function _migrate(uint64 /* from */ ) internal virtual {
        revert BadOperation();
    }

    /// @dev Upgrades happen only through `scheduleUpgrade` → delay → `executeScheduled` (the vault
    ///      calling itself), and only to a newer implementation the registry approves at that moment.
    function _authorizeUpgrade(address newImplementation) internal view override {
        if (msg.sender != address(this)) revert NotTimelocked();
        _requireUpgradeAllowed(newImplementation);
    }

    function _requireUpgradeAllowed(address newImplementation) internal view {
        IEPKRegistry r = IEPKRegistry(registry);
        if (!r.isApproved(newImplementation)) revert ImplementationNotApproved(newImplementation);
        uint64 v = r.versionOf(newImplementation);
        if (v <= vaultVersion()) revert NotNewerVersion(vaultVersion(), v);
    }

    function setRecovery(address newRecovery) external onlyTimelocked {
        if (newRecovery == admin || newRecovery == address(this) || isGuardian[newRecovery] || _isSessionManager(newRecovery))
        {
            revert BadRole(newRecovery);
        }
        recovery = newRecovery;
        emit RecoverySet(newRecovery);
    }

    // ---------------------------------------------------------------------
    // Execution
    // ---------------------------------------------------------------------

    /// @notice Agent submits a batch of calls signed by the policy's operator signer. The signature
    ///         binds the agent, so only that agent can submit it.
    /// @param coSignature co-signer's signature over `getCoSignDigest(executeDigest)`; required only
    ///        when this batch moves more than an asset's `coSignAbove` (pass empty bytes otherwise).
    // slither-disable-start reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events
    // Reentrancy (reviewed, tested): state written after the external calls is the outflow accounting,
    // which by design must measure balances AFTER the batch has run. The whole function holds the
    // `nonReentrant` lock shared with `executeScheduled`, so the batch cannot re-enter either of them;
    // every other state-changing entry point is restricted to the admin, guardians, recovery key or
    // the vault itself (onlyTimelocked), none of which a call target is. The nonce is consumed before
    // any external call. Proof: test/v2/EPKVault.reentrancy.t.sol.
    /// @dev Token allowances created inside the batch must be back to zero when it ends
    ///      (pattern: approve → use → approve(0)), so no allowance can be pulled later.
    function execute(
        uint256 policyId,
        Call[] calldata calls,
        uint256 deadline,
        bytes calldata signature,
        bytes calldata coSignature
    ) external nonReentrant returns (bytes[] memory results) {
        // 1) vault, policy, deadline and agent checks
        Policy memory p = _loadExecutablePolicy(policyId, calls.length, deadline);
        // 2) static rules for every call; remember allowances that must be zero at the end
        Approvals memory approvals = _checkCalls(policyId, p, calls);
        // 3) operator signature (bound to policy, agent, calls, nonce, deadline, vault, chain),
        //    optional validator, nonce increment
        bytes32 digest = _authorize(policyId, p, calls, deadline, signature);
        // 4) run the batch, measuring real balance changes
        uint256[] memory balancesBefore = _snapshotBalances();
        results = _runCalls(policyId, calls);
        // 5) the guard checks the real result of the batch (e.g. swap outputs actually received)
        if (p.validator != address(0)) IEPKGuard(p.validator).afterBatch(policyId);
        // 6) charge outflows; no allowance may survive the batch
        _settleOutflows(policyId, p.envelope, balancesBefore, digest, coSignature);
        _requireAllowancesCleared(approvals);

        emit Executed(policyId, p.signer, msg.sender, nonces[policyId] - 1, calls.length);
    }
    // slither-disable-end reentrancy-eth,reentrancy-no-eth,reentrancy-benign,reentrancy-events

    struct Approvals {
        address[] tokens;
        address[] spenders;
        uint256 count;
    }

    // slither-disable-start timestamp
    // timestamp: deadline/TTL checks with minute-to-day granularity; validator skew is irrelevant.
    function _loadExecutablePolicy(uint256 policyId, uint256 callCount, uint256 deadline)
        internal
        view
        returns (Policy memory p)
    {
        if (!setupDone) revert SetupNotFinished();
        if (paused) revert IsPaused();
        if (callCount == 0 || callCount > MAX_CALLS) revert BadCalldata();

        p = policies[policyId];
        if (p.signer == address(0)) revert PolicyNotFound();
        if (!p.active || p.epoch != epoch) revert PolicyInactive();
        if (p.envelope != 0) _applyEnvelope(p);

        if (deadline == 0) revert DeadlineRequired();
        if (deadline <= block.timestamp) revert Expired();
        if (p.validUntil != 0 && block.timestamp > p.validUntil) revert Expired();
        _requireAgent(policyId);
    }

    /// @dev Sessions follow their envelope live: switched off (or switched off and back on) ends them,
    ///      a lowered value cap applies at once, and the envelope's guard is the session's guard.
    function _applyEnvelope(Policy memory p) internal view {
        Envelope memory e = envelopes[p.envelope - 1];
        if (!e.active || e.generation != p.generation) revert PolicyInactive();
        if (e.maxValuePerCall < p.maxValuePerCall) p.maxValuePerCall = e.maxValuePerCall;
        p.validator = envelopeGuard[p.envelope - 1];
    }

    function _requireAgent(uint256 policyId) internal view {
        AgentPermission memory ap = agentPermission[policyId][msg.sender];
        if (!ap.allowed) revert AgentNotAllowed();
        if (ap.validUntil != 0 && block.timestamp > ap.validUntil) revert AgentExpired();
    }
    // slither-disable-end timestamp

    /// @dev An unguarded session may only make the calls the vault inspects itself: any other call
    ///      (a swap, a lending call, anything the vault cannot read) needs the envelope's guard.
    function _checkCalls(uint256 policyId, Policy memory p, Call[] calldata calls)
        internal
        view
        returns (Approvals memory a)
    {
        uint256 n = calls.length;
        a.tokens = new address[](n);
        a.spenders = new address[](n);
        bool unguardedSession = p.envelope != 0 && p.validator == address(0);
        for (uint256 i = 0; i < n; i++) {
            if (unguardedSession && !_isInspected(calls[i].data)) revert GuardRequired();
            address spender = _checkCall(policyId, p.envelope, p.maxValuePerCall, calls[i]);
            if (spender != address(0)) {
                a.tokens[a.count] = calls[i].target;
                a.spenders[a.count] = spender;
                a.count++;
            }
        }
    }

    // slither-disable-start calls-loop
    // calls-loop: at most MAX_CALLS validator calls; the validator is chosen by the vault's own admin,
    // so a reverting validator can only block this vault's own policy.
    /// @dev Checks-effects-interactions: the nonce is consumed BEFORE the external validator is called.
    function _authorize(
        uint256 policyId,
        Policy memory p,
        Call[] calldata calls,
        uint256 deadline,
        bytes calldata signature
    ) internal returns (bytes32 digest) {
        uint256 nonce = nonces[policyId];
        digest = _executeDigest(policyId, msg.sender, calls, nonce, deadline);
        if (!_isValidSignature(p.signer, digest, signature)) revert BadSignature();
        nonces[policyId] = nonce + 1;

        if (p.validator != address(0)) {
            for (uint256 i = 0; i < calls.length; i++) {
                IPolicyValidator(p.validator).validate(
                    policyId, p.signer, msg.sender, calls[i].target, calls[i].value, calls[i].data
                );
            }
        }
    }
    // slither-disable-end calls-loop

    // slither-disable-start arbitrary-send-eth,low-level-calls,calls-loop
    // arbitrary-send-eth (reviewed, tested): sending value to the batch targets IS the vault's job.
    // Before this point `_checkCall` has required, for every call: target allowlisted for the policy,
    // value <= maxValuePerCall, native asset tracked and target an allowlisted destination; the batch
    // is signed by the policy signer and submitted by an allowed agent; afterwards the real outflow is
    // charged against the per-window limit. Proof: test/v2/EPKVault.reentrancy.t.sol and the
    // invariants in test/v2/EPKVault.invariant.t.sol.
    // low-level-calls: arbitrary calldata must be forwarded; the result is checked and bubbled.
    // calls-loop: at most MAX_CALLS calls, all signed by the policy signer.
    function _runCalls(uint256 policyId, Call[] calldata calls) internal returns (bytes[] memory results) {
        uint256 n = calls.length;
        results = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            Call calldata c = calls[i];
            (bool ok, bytes memory ret) = c.target.call{value: c.value}(c.data);
            ret = Address.verifyCallResult(ok, ret);
            _checkTokenReturn(c, ret);
            results[i] = ret;
            emit CallExecuted(policyId, c.target, _selectorOf(c.data), c.value);
        }
    }
    // slither-disable-end arbitrary-send-eth,low-level-calls,calls-loop

    // slither-disable-start calls-loop
    // calls-loop: at most MAX_CALLS allowance reads on tokens the vault's admin chose to track.
    function _requireAllowancesCleared(Approvals memory a) internal view {
        for (uint256 j = 0; j < a.count; j++) {
            if (IERC20Minimal(a.tokens[j]).allowance(address(this), a.spenders[j]) != 0) {
                revert AllowanceLeft(a.tokens[j], a.spenders[j]);
            }
        }
    }
    // slither-disable-end calls-loop

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function trackedAssets() external view returns (address[] memory) {
        return _trackedAssets;
    }

    /// @notice How much of `token` can leave the vault right now.
    function availableToSpend(address token) external view returns (uint256) {
        Asset storage a = assets[token];
        if (!a.tracked) return 0;
        return _available(a);
    }

    /// @notice How much of `token` a budgeted policy (session) may still move right now.
    function budgetAvailable(uint256 policyId, address token) external view returns (uint256) {
        uint64 envelope = policies[policyId].envelope;
        Asset storage a = assets[token];
        if (envelope == 0 || !a.tracked) return 0;
        return _sessionAvailable(policyBudgets[policyId][token], envelopeBudgetCap[envelope - 1][token], a.window);
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }

    /// @notice EIP-712 digest the operator signer signs.
    function getExecuteDigest(uint256 policyId, address agent, Call[] calldata calls, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        return _executeDigest(policyId, agent, calls, nonce, deadline);
    }

    /// @notice EIP-712 digest the co-signer signs (distinct from the operator's digest).
    function getCoSignDigest(bytes32 executeDigest) public view returns (bytes32) {
        return _hashTypedData(keccak256(abi.encode(_COSIGN_TYPEHASH, executeDigest)));
    }

    // ---------------------------------------------------------------------
    // Internal: rules
    // ---------------------------------------------------------------------

    /// @return spender non-zero when this call grants an allowance that must be gone at the end.
    /// @dev Policies use their own call allowlist; sessions use their envelope's (live: narrowing the
    ///      envelope narrows every open session).
    function _checkCall(uint256 policyId, uint64 envelope, uint256 maxValuePerCall, Call calldata c)
        internal
        view
        returns (address spender)
    {
        address target = c.target;
        if (target == address(0) || target == address(this)) revert BadTarget();
        bytes4 sel = _selectorOf(c.data);
        bytes32 key = _callKey(target, sel);
        if (!(envelope == 0 ? callAllowed[policyId][key] : envelopeCallAllowed[envelope - 1][key])) {
            revert CallNotAllowed();
        }
        if (c.value > maxValuePerCall) revert ValueTooHigh();

        if (c.value > 0) {
            if (!assets[NATIVE].tracked) revert UntrackedAsset(NATIVE);
            if (!isDestination[target]) revert DestinationNotAllowed(target);
        }
        if (c.data.length < 4) return address(0);
        spender = _checkTokenCall(target, sel, c.data);
    }

    /// @dev Recipient / spender rules for the ERC-20 (and ERC-721-shaped) calls the vault understands.
    function _checkTokenCall(address target, bytes4 sel, bytes calldata data) internal view returns (address spender) {
        if (sel == _SEL_TRANSFER) {
            if (!assets[target].tracked) revert UntrackedAsset(target);
            _requireDestination(_addressArg(data, 0));
        } else if (sel == _SEL_TRANSFER_FROM) {
            if (_addressArg(data, 0) == address(this) && !assets[target].tracked) revert UntrackedAsset(target);
            _requireDestination(_addressArg(data, 1));
        } else if (sel == _SEL_APPROVE || sel == _SEL_INCREASE_ALLOWANCE) {
            address s = _addressArg(data, 0);
            // spender checked even for amount 0: for ERC-721 approve(x, 0) means token #0, not a revoke
            if (s != address(0)) _requireDestination(s);
            if (_uintArg(data, 1) != 0) {
                if (!assets[target].tracked) revert UntrackedAsset(target);
                spender = s;
            }
        } else if (sel == _SEL_SET_APPROVAL_FOR_ALL) {
            if (_uintArg(data, 1) != 0) revert ForbiddenApproval();
        }
    }

    /// @dev Plain native transfers and the token calls `_checkTokenCall` understands.
    function _isInspected(bytes calldata data) internal pure returns (bool) {
        if (data.length < 4) return true;
        bytes4 sel = bytes4(data[:4]);
        return sel == _SEL_TRANSFER || sel == _SEL_TRANSFER_FROM || sel == _SEL_APPROVE
            || sel == _SEL_INCREASE_ALLOWANCE || sel == _SEL_SET_APPROVAL_FOR_ALL;
    }

    function _requireDestination(address d) internal view {
        if (!isDestination[d]) revert DestinationNotAllowed(d);
    }

    /// @dev Tokens that signal failure by returning false (instead of reverting) must not pass silently.
    function _checkTokenReturn(Call calldata c, bytes memory ret) internal pure {
        if (c.data.length < 4 || ret.length != 32) return;
        bytes4 sel = bytes4(c.data[:4]);
        if (sel == _SEL_TRANSFER || sel == _SEL_TRANSFER_FROM || sel == _SEL_APPROVE || sel == _SEL_INCREASE_ALLOWANCE)
        {
            if (abi.decode(ret, (uint256)) == 0) revert TokenCallFailed(c.target);
        }
    }

    function _snapshotBalances() internal view returns (uint256[] memory balances) {
        uint256 n = _trackedAssets.length;
        balances = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            balances[i] = _balanceOf(_trackedAssets[i]);
        }
    }

    // slither-disable-start timestamp
    // timestamp: the limit refills over windows of hours/days; seconds of validator skew are irrelevant.
    /// @dev Charges every real decrease of a tracked balance against that asset's vault-wide bucket and,
    ///      for budgeted policies (sessions), against the policy's own budget for that asset.
    function _settleOutflows(
        uint256 policyId,
        uint64 envelope,
        uint256[] memory balancesBefore,
        bytes32 digest,
        bytes calldata coSignature
    ) internal {
        bool coSigned = false;
        uint256 n = balancesBefore.length;
        for (uint256 i = 0; i < n; i++) {
            address token = _trackedAssets[i];
            uint256 afterBal = _balanceOf(token);
            if (afterBal >= balancesBefore[i]) continue;

            uint256 amount = balancesBefore[i] - afterBal;
            Asset storage a = assets[token];

            if (amount > a.coSignAbove && !coSigned) {
                address cs = coSigner;
                if (cs == address(0) || !_isValidSignature(cs, getCoSignDigest(digest), coSignature)) {
                    revert CoSignatureRequired(token, amount);
                }
                coSigned = true;
            }

            uint256 avail = _available(a);
            if (amount > avail) revert LimitExceeded(token, amount, avail);
            unchecked {
                avail -= amount;
            }
            a.available = uint128(avail);
            a.lastUpdate = uint64(block.timestamp);
            emit Outflow(token, amount, avail);

            if (envelope != 0) _chargeBudget(policyId, envelope - 1, token, amount, a.window);
        }
    }

    /// @dev A session can only move assets its envelope gives a budget for (fail closed).
    function _chargeBudget(uint256 policyId, uint256 envelopeId, address token, uint256 amount, uint32 window)
        internal
    {
        Budget storage b = policyBudgets[policyId][token];
        uint256 avail = _sessionAvailable(b, envelopeBudgetCap[envelopeId][token], window);
        if (amount > avail) revert BudgetExceeded(token, amount, avail);
        unchecked {
            avail -= amount;
        }
        b.available = uint128(avail);
        b.lastUpdate = uint64(block.timestamp);
    }

    function _available(Asset storage a) internal view returns (uint256) {
        return _refilled(a.maxPerWindow, a.available, a.lastUpdate, a.window);
    }

    /// @dev An untouched session bucket is full; the envelope's current cap always bounds it.
    function _sessionAvailable(Budget storage b, uint256 cap, uint32 window) internal view returns (uint256) {
        if (b.lastUpdate == 0) return cap;
        return _refilled(cap, b.available, b.lastUpdate, window);
    }

    /// @dev Token bucket: refills linearly from empty to `cap` over `window` seconds.
    function _refilled(uint256 cap, uint256 avail, uint64 lastUpdate, uint32 window) internal view returns (uint256) {
        if (cap == 0) return 0;
        uint256 v = avail + (block.timestamp - uint256(lastUpdate)) * cap / uint256(window);
        return v < cap ? v : cap;
    }
    // slither-disable-end timestamp

    // slither-disable-start calls-loop
    // calls-loop: balance reads over at most MAX_TRACKED_ASSETS tokens the vault's admin chose to track.
    function _balanceOf(address token) internal view returns (uint256) {
        if (token == NATIVE) return address(this).balance;
        return IERC20Minimal(token).balanceOf(address(this));
    }
    // slither-disable-end calls-loop

    // slither-disable-start timestamp
    // timestamp: false positive — compares the release version, not a time (see `cancel`).
    /// @dev Existence sentinel: every scheduled operation records a non-zero release version.
    function _exists(Operation memory op) internal pure returns (bool) {
        return op.version != 0;
    }
    // slither-disable-end timestamp

    // slither-disable-start timestamp
    // timestamp: readiness / grace-period arithmetic over hours to weeks; validator skew is irrelevant.
    function _schedule(
        bytes memory data,
        bytes32 salt,
        uint256 wait,
        bool epochExempt,
        bool adminCannotCancel,
        address shielded
    ) internal returns (bytes32 id) {
        id = hashOperation(data, salt);
        Operation memory existing = operations[id];
        // a live operation blocks the id, except that a recovery operation replaces a look-alike
        // non-recovery operation (so a compromised admin cannot squat the recovery's id)
        if (_exists(existing) && _isLive(existing) && !(adminCannotCancel && !existing.adminCannotCancel)) {
            revert OperationExists();
        }
        uint64 readyAt = uint64(block.timestamp + wait);
        operations[id] = Operation({
            readyAt: readyAt,
            epoch: epoch,
            epochExempt: epochExempt,
            adminCannotCancel: adminCannotCancel,
            shielded: shielded,
            version: vaultVersion()
        });
        emit OperationScheduled(id, data, salt, readyAt, msg.sender);
    }

    /// @dev Ordinary operations die with a panic/revokeAll (epoch) and with an upgrade (version), so
    ///      nothing scheduled under one release's rules runs under another's. Shielded guardian
    ///      changes and recovery operations survive both.
    function _isLive(Operation memory op) internal view returns (bool) {
        return (op.epochExempt || (op.epoch == epoch && op.version == vaultVersion()))
            && block.timestamp <= uint256(op.readyAt) + GRACE_PERIOD;
    }
    // slither-disable-end timestamp

    function _bumpEpoch() internal {
        uint64 e = epoch + 1;
        epoch = e;
        emit EpochBumped(e, msg.sender);
    }

    function _requirePolicy(uint256 policyId) internal view {
        if (policies[policyId].signer == address(0)) revert PolicyNotFound();
    }

    function _callKey(address target, bytes4 selector) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(target, selector));
    }

    /// @dev Empty calldata = plain native transfer. Non-empty calldata may never use the zero selector,
    ///      so the native-transfer permission cannot be used to run arbitrary fallback logic.
    function _selectorOf(bytes calldata data) internal pure returns (bytes4 sel) {
        if (data.length == 0) return NATIVE_TRANSFER_SELECTOR;
        if (data.length < 4) revert BadCalldata();
        sel = bytes4(data[:4]);
        if (sel == NATIVE_TRANSFER_SELECTOR) revert BadCalldata();
    }

    function _uintArg(bytes calldata data, uint256 index) internal pure returns (uint256) {
        uint256 offset = 4 + 32 * index;
        if (data.length < offset + 32) revert BadCalldata();
        return uint256(bytes32(data[offset:offset + 32]));
    }

    function _addressArg(bytes calldata data, uint256 index) internal pure returns (address) {
        uint256 v = _uintArg(data, index);
        if (v >> 160 != 0) revert BadCalldata();
        return address(uint160(v));
    }

    // ---------------------------------------------------------------------
    // Internal: signatures (EIP-712, ECDSA or ERC-1271)
    // ---------------------------------------------------------------------

    function _executeDigest(uint256 policyId, address agent, Call[] calldata calls, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        uint256 n = calls.length;
        bytes32[] memory hashes = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            hashes[i] = keccak256(abi.encode(_CALL_TYPEHASH, calls[i].target, calls[i].value, keccak256(calls[i].data)));
        }
        bytes32 callsHash = keccak256(abi.encodePacked(hashes));
        return _hashTypedData(keccak256(abi.encode(_EXECUTE_TYPEHASH, policyId, agent, callsHash, nonce, deadline)));
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH,
                keccak256(bytes(EIP712_NAME)),
                keccak256(bytes(EIP712_VERSION)),
                block.chainid,
                address(this)
            )
        );
    }

    /// @dev Computed on every call: behind a proxy `address(this)` is the vault, and the chain id is
    ///      always current (fork-safe).
    function _domainSeparator() internal view returns (bytes32) {
        return _buildDomainSeparator();
    }

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    // slither-disable-start low-level-calls
    // low-level-calls: a staticcall, so the answer can be checked to be EXACTLY the 32-byte ERC-1271
    // magic value (a high-level call would revert on malformed answers instead of returning false).
    /// @dev ECDSA first (OpenZeppelin ECDSA: 65-byte signatures, low-s enforced; covers EOAs including
    ///      EIP-7702 delegated ones), then ERC-1271 for contracts such as multisigs or MPC wallets.
    function _isValidSignature(address signer, bytes32 digest, bytes calldata signature)
        internal
        view
        returns (bool)
    {
        if (_recoverOrZero(digest, signature) == signer) return true;
        if (signer.code.length == 0) return false;
        (bool ok, bytes memory ret) =
            signer.staticcall(abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, signature));
        return ok && ret.length == 32 && abi.decode(ret, (bytes32)) == bytes32(_ERC1271_MAGIC);
    }
    // slither-disable-end low-level-calls

    // slither-disable-start unused-return
    // unused-return: the third value is only a diagnostic argument of the error (length or s value);
    // any error at all is treated as "no valid ECDSA signature".
    /// @dev OpenZeppelin ECDSA recovery; address(0) for any malformed, high-s or invalid signature
    ///      (address(0) never matches a signer: signers are checked to be non-zero).
    function _recoverOrZero(bytes32 digest, bytes calldata signature) internal pure returns (address recovered) {
        ECDSA.RecoverError err;
        (recovered, err,) = ECDSA.tryRecoverCalldata(digest, signature);
        if (err != ECDSA.RecoverError.NoError) return address(0);
    }
    // slither-disable-end unused-return
}
