// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPolicyValidator} from "../epk/IPolicyValidator.sol";

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
///         - one-call kill switch (`panic`) that pauses and invalidates every policy and pending change.
/// @dev Threat model: the operator signer, the agent and the co-signer may all be compromised at the
///      same time. Damage is then bounded by `maxPerWindow` per tracked asset and by the destination
///      allowlist. See docs/SPEC_v2.md and docs/SECURITY_REVIEW_v2.md.
contract EPKVault {
    // ---------------------------------------------------------------------
    // Types & constants
    // ---------------------------------------------------------------------

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    string public constant EIP712_NAME = "EPK Vault";
    string public constant EIP712_VERSION = "2";

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
    bytes4 public constant NATIVE_TRANSFER_SELECTOR = 0x00000000;

    uint256 public constant MIN_DELAY = 1 hours;
    uint256 public constant MAX_DELAY = 30 days;
    /// @notice A ready operation must be executed within this period, otherwise it goes stale.
    uint256 public constant GRACE_PERIOD = 14 days;
    uint256 public constant MAX_TRACKED_ASSETS = 16;
    uint256 public constant MAX_CALLS = 16;
    /// @notice Guardians required before the vault can go live (admin is never a guardian).
    uint256 public constant MIN_GUARDIANS = 2;

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
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    address public admin;
    address public recovery;
    mapping(address => bool) public isGuardian;
    uint256 public guardianCount;
    address public coSigner;

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

    mapping(bytes32 => Operation) public operations;

    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event RecoverySet(address indexed recovery);
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

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyAdminOrGuardian() {
        if (msg.sender != admin && !isGuardian[msg.sender]) revert NotAdminOrGuardian();
        _;
    }

    /// @dev Loosening changes: only through the timelock (the vault calling itself), or directly by
    ///      the admin while the initial setup is still open (no funds can move before setup ends).
    modifier onlyTimelocked() {
        if (msg.sender != address(this) && (setupDone || msg.sender != admin)) revert NotTimelocked();
        _;
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

    /// @param recovery_ optional cold key that can replace a lost or compromised admin (0 = none).
    constructor(address admin_, address[] memory guardians_, uint256 delay_, address recovery_) {
        if (admin_ == address(0)) revert ZeroAddress();
        if (delay_ < MIN_DELAY || delay_ > MAX_DELAY) revert BadDelay();

        admin = admin_;
        delay = delay_;
        emit AdminChanged(address(0), admin_);
        emit DelaySet(delay_);

        for (uint256 i = 0; i < guardians_.length; i++) {
            address g = guardians_[i];
            if (g == address(0)) revert ZeroAddress();
            if (g == admin_ || g == recovery_ || isGuardian[g]) revert BadRole(g);
            isGuardian[g] = true;
            emit GuardianSet(g, true);
        }
        guardianCount = guardians_.length;

        if (recovery_ == admin_) revert BadRole(recovery_);
        recovery = recovery_;
        emit RecoverySet(recovery_);

        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
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
        address shielded;
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

    function executeScheduled(bytes calldata data, bytes32 salt) external nonReentrant {
        if (msg.sender != admin && msg.sender != recovery) revert NotAdminOrRecovery();
        bytes32 id = hashOperation(data, salt);
        Operation memory op = operations[id];
        if (op.readyAt == 0) revert UnknownOperation();
        if (!_isLive(op)) revert StaleOperation();
        if (block.timestamp < op.readyAt) revert OperationNotReady();
        delete operations[id];

        (bool ok, bytes memory ret) = address(this).call(data);
        if (!ok) _bubble(ret);
        emit OperationExecuted(id);
    }

    /// @notice Admin or any guardian can veto a pending change (see shielding rules).
    function cancel(bytes32 id) external onlyAdminOrGuardian {
        Operation memory op = operations[id];
        if (op.readyAt == 0) revert UnknownOperation();
        if (msg.sender == op.shielded || (msg.sender == admin && op.adminCannotCancel)) revert CannotCancel();
        delete operations[id];
        emit OperationCancelled(id, msg.sender);
    }

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

    /// @notice Deactivates a policy and invalidates any signature already queued for it.
    function revokePolicy(uint256 policyId) external onlyAdminOrGuardian {
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

    function disallowCall(uint256 policyId, address target, bytes4 selector) external onlyAdminOrGuardian {
        _requirePolicy(policyId);
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
        policyId = nextPolicyId++;
        policies[policyId] = Policy({
            signer: signer,
            active: true,
            validUntil: validUntil,
            epoch: epoch,
            maxValuePerCall: maxValuePerCall,
            validator: validator
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
        _requirePolicy(policyId);
        if (signer == address(0)) revert ZeroAddress();
        Policy storage p = policies[policyId];
        p.signer = signer;
        p.validUntil = validUntil;
        p.maxValuePerCall = maxValuePerCall;
        p.validator = validator;
        emit PolicyUpdated(policyId, signer, validUntil, maxValuePerCall, validator);
    }

    function setPolicyActive(uint256 policyId, bool active) external onlyTimelocked {
        _requirePolicy(policyId);
        policies[policyId].active = active;
        emit PolicyStatus(policyId, active);
    }

    function setAgent(uint256 policyId, address agent, bool allowed, uint40 validUntil) external onlyTimelocked {
        _requirePolicy(policyId);
        if (agent == address(0)) revert ZeroAddress();
        agentPermission[policyId][agent] = AgentPermission({allowed: allowed, validUntil: validUntil});
        emit AgentSet(policyId, agent, allowed, validUntil);
    }

    function setCall(uint256 policyId, address target, bytes4 selector, bool allowed) external onlyTimelocked {
        _requirePolicy(policyId);
        if (target == address(0) || target == address(this)) revert BadTarget();
        callAllowed[policyId][_callKey(target, selector)] = allowed;
        emit CallSet(policyId, target, selector, allowed);
    }

    function addDestination(address destination) external onlyTimelocked {
        if (destination == address(0) || destination == address(this)) revert BadTarget();
        isDestination[destination] = true;
        emit DestinationSet(destination, true);
    }

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

    function untrackAsset(address token) external onlyTimelocked {
        if (!assets[token].tracked) revert UntrackedAsset(token);
        delete assets[token];
        uint256 n = _trackedAssets.length;
        for (uint256 i = 0; i < n; i++) {
            if (_trackedAssets[i] == token) {
                _trackedAssets[i] = _trackedAssets[n - 1];
                _trackedAssets.pop();
                break;
            }
        }
        emit AssetUntracked(token);
    }

    function setCoSigner(address newCoSigner) external onlyTimelocked {
        coSigner = newCoSigner;
        emit CoSignerSet(newCoSigner);
    }

    function setGuardian(address guardian, bool enabled) external onlyTimelocked {
        if (guardian == address(0)) revert ZeroAddress();
        if (isGuardian[guardian] == enabled) return;
        if (enabled) {
            if (guardian == admin || guardian == recovery || guardian == address(this)) revert BadRole(guardian);
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
                || newGuardian == address(this)
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
        if (newAdmin == address(this) || isGuardian[newAdmin] || newAdmin == recovery) revert BadRole(newAdmin);
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    function setRecovery(address newRecovery) external onlyTimelocked {
        if (newRecovery == admin || newRecovery == address(this) || isGuardian[newRecovery]) {
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
        Approvals memory approvals = _checkCalls(policyId, p.maxValuePerCall, calls);
        // 3) operator signature (bound to policy, agent, calls, nonce, deadline, vault, chain),
        //    optional validator, nonce increment
        bytes32 digest = _authorize(policyId, p, calls, deadline, signature);
        // 4) run the batch, measuring real balance changes
        uint256[] memory balancesBefore = _snapshotBalances();
        results = _runCalls(policyId, calls);
        // 5) charge outflows; no allowance may survive the batch
        _settleOutflows(balancesBefore, digest, coSignature);
        _requireAllowancesCleared(approvals);

        emit Executed(policyId, p.signer, msg.sender, nonces[policyId] - 1, calls.length);
    }

    struct Approvals {
        address[] tokens;
        address[] spenders;
        uint256 count;
    }

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

        if (deadline == 0) revert DeadlineRequired();
        if (deadline <= block.timestamp) revert Expired();
        if (p.validUntil != 0 && block.timestamp > p.validUntil) revert Expired();

        AgentPermission memory ap = agentPermission[policyId][msg.sender];
        if (!ap.allowed) revert AgentNotAllowed();
        if (ap.validUntil != 0 && block.timestamp > ap.validUntil) revert AgentExpired();
    }

    function _checkCalls(uint256 policyId, uint256 maxValuePerCall, Call[] calldata calls)
        internal
        view
        returns (Approvals memory a)
    {
        uint256 n = calls.length;
        a.tokens = new address[](n);
        a.spenders = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            address spender = _checkCall(policyId, maxValuePerCall, calls[i]);
            if (spender != address(0)) {
                a.tokens[a.count] = calls[i].target;
                a.spenders[a.count] = spender;
                a.count++;
            }
        }
    }

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

        if (p.validator != address(0)) {
            for (uint256 i = 0; i < calls.length; i++) {
                IPolicyValidator(p.validator).validate(
                    policyId, p.signer, msg.sender, calls[i].target, calls[i].value, calls[i].data
                );
            }
        }
        nonces[policyId] = nonce + 1;
    }

    function _runCalls(uint256 policyId, Call[] calldata calls) internal returns (bytes[] memory results) {
        uint256 n = calls.length;
        results = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            Call calldata c = calls[i];
            (bool ok, bytes memory ret) = c.target.call{value: c.value}(c.data);
            if (!ok) _bubble(ret);
            _checkTokenReturn(c, ret);
            results[i] = ret;
            emit CallExecuted(policyId, c.target, _selectorOf(c.data), c.value);
        }
    }

    function _requireAllowancesCleared(Approvals memory a) internal view {
        for (uint256 j = 0; j < a.count; j++) {
            if (IERC20Minimal(a.tokens[j]).allowance(address(this), a.spenders[j]) != 0) {
                revert AllowanceLeft(a.tokens[j], a.spenders[j]);
            }
        }
    }

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
    function _checkCall(uint256 policyId, uint256 maxValuePerCall, Call calldata c)
        internal
        view
        returns (address spender)
    {
        address target = c.target;
        if (target == address(0) || target == address(this)) revert BadTarget();
        bytes4 sel = _selectorOf(c.data);
        if (!callAllowed[policyId][_callKey(target, sel)]) revert CallNotAllowed();
        if (c.value > maxValuePerCall) revert ValueTooHigh();

        if (c.value > 0) {
            if (!assets[NATIVE].tracked) revert UntrackedAsset(NATIVE);
            if (!isDestination[target]) revert DestinationNotAllowed(target);
        }
        if (c.data.length < 4) return address(0);

        bytes calldata data = c.data;
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

    /// @dev Charges every real decrease of a tracked balance against that asset's bucket.
    function _settleOutflows(uint256[] memory balancesBefore, bytes32 digest, bytes calldata coSignature) internal {
        bool coSigned;
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
        }
    }

    function _available(Asset storage a) internal view returns (uint256) {
        uint256 cap = a.maxPerWindow;
        uint256 refill = (block.timestamp - uint256(a.lastUpdate)) * cap / uint256(a.window);
        uint256 avail = uint256(a.available) + refill;
        return avail < cap ? avail : cap;
    }

    function _balanceOf(address token) internal view returns (uint256) {
        if (token == NATIVE) return address(this).balance;
        return IERC20Minimal(token).balanceOf(address(this));
    }

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
        if (existing.readyAt != 0 && _isLive(existing)) revert OperationExists();
        uint64 readyAt = uint64(block.timestamp + wait);
        operations[id] = Operation({
            readyAt: readyAt,
            epoch: epoch,
            epochExempt: epochExempt,
            adminCannotCancel: adminCannotCancel,
            shielded: shielded
        });
        emit OperationScheduled(id, data, salt, readyAt, msg.sender);
    }

    function _isLive(Operation memory op) internal view returns (bool) {
        return (op.epochExempt || op.epoch == epoch) && block.timestamp <= uint256(op.readyAt) + GRACE_PERIOD;
    }

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

    function _uintArg(bytes calldata data, uint256 index) internal pure returns (uint256 v) {
        uint256 offset = 4 + 32 * index;
        if (data.length < offset + 32) revert BadCalldata();
        assembly {
            v := calldataload(add(data.offset, offset))
        }
    }

    function _addressArg(bytes calldata data, uint256 index) internal pure returns (address) {
        uint256 v = _uintArg(data, index);
        if (v >> 160 != 0) revert BadCalldata();
        return address(uint160(v));
    }

    function _bubble(bytes memory ret) internal pure {
        assembly {
            revert(add(ret, 0x20), mload(ret))
        }
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

    function _domainSeparator() internal view returns (bytes32) {
        return block.chainid == _CACHED_CHAIN_ID ? _CACHED_DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    /// @dev ECDSA first (covers EOAs, including EIP-7702 delegated ones), then ERC-1271 for contracts
    ///      such as multisigs or MPC wallets. The 1271 answer must be exactly the ABI-encoded magic.
    function _isValidSignature(address signer, bytes32 digest, bytes calldata signature)
        internal
        view
        returns (bool)
    {
        if (_recover(digest, signature) == signer) return true;
        if (signer.code.length == 0) return false;
        (bool ok, bytes memory ret) =
            signer.staticcall(abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, signature));
        return ok && ret.length == 32 && abi.decode(ret, (bytes32)) == bytes32(_ERC1271_MAGIC);
    }

    /// @dev Returns address(0) for any malformed or high-s signature.
    function _recover(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return address(0);
        if (uint256(s) > 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0) return address(0);
        return ecrecover(digest, v, r, s);
    }
}
