// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IEPKGuard} from "./IEPKGuard.sol";
import {IVersionedVault} from "../IEPK.sol";

interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
}

/// @title EPK DexGuard — safe token swaps for trading bots and AI agents
/// @notice Immutable rule set for one trading setup. For every call of a batch:
///
///         - a call to a configured router must be one of the supported swap functions, and the swap must
///           send its output to the vault, use only listed tokens, expire soon, and accept no worse than
///           the Chainlink fair price minus `maxSlippageBps` (or pay no more than the fair price plus it);
///         - a token approval with a non-zero amount must go to a configured router, for a listed token;
///         - plain token transfers, allowance resets and native transfers pass (the vault itself checks
///           their recipients and limits);
///         - everything else is rejected: unknown functions, multicall, fee-on-transfer variants,
///           liquidity functions, other contracts.
///
///         On vaults from 2.1.0 the guard also checks the REAL result after the batch: every asset a swap
///         touched must end with at least the guaranteed net change (minimum outputs in, maximum inputs
///         out). A router or token that delivers less than promised fails the whole batch.
///
///         No price, a stale price or a price outside the configured bounds rejects the swap.
///         Nothing here can be changed after deployment: new rules are a new guard, switched in through
///         the vault's timelock.
contract DexGuard is IEPKGuard {
    using SafeCast for uint256;

    enum RouterKind {
        None,
        V2, // Uniswap V2 / PancakeSwap V2 style router
        V3 // Uniswap V3 SwapRouter / PancakeSwap V3 SwapRouter style (deadline inside the params)
    }

    struct RouterInit {
        address router;
        RouterKind kind;
    }

    struct TokenInit {
        address token;
        address feed; // Chainlink-compatible price feed, all feeds in the same quote currency (e.g. USD)
        uint32 maxAge; // seconds: an older answer is stale
        uint256 maxAmountIn; // largest amount of this token one swap may spend
        uint128 minPrice; // sanity bounds for the feed answer (feed decimals), e.g. circuit-breaker clamps
        uint128 maxPrice;
    }

    struct TokenConfig {
        address feed;
        uint8 tokenDecimals;
        uint8 feedDecimals;
        uint32 maxAge;
        uint256 maxAmountIn;
        uint128 minPrice;
        uint128 maxPrice;
    }

    /// @dev One asset a swap in the current batch touched, for the after-batch balance check.
    struct Pending {
        address asset; // NATIVE = address(0)
        uint256 before; // vault balance before the batch ran
        int256 minDelta; // guaranteed net change: + minimum outputs, - maximum inputs
    }

    // Uniswap V3 SwapRouter parameter structs (with deadline)
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    /// @dev Swap facts extracted from one router call.
    struct Swap {
        address tokenIn; // priced token (wrapped native for native-in swaps)
        address tokenOut;
        address assetIn; // balance that pays (NATIVE for native-in swaps)
        address assetOut; // balance that receives (NATIVE for native-out swaps)
        address recipient;
        uint256 deadline;
        bool exactIn;
        uint256 amount; // exact-in: amount in; exact-out: amount out
        uint256 limit; // exact-in: minimum out; exact-out: maximum in
    }

    address public constant NATIVE = address(0);
    uint64 public constant POST_CHECK_FROM_VERSION = 20_100; // vault 2.1.0 calls afterBatch
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000; // 10 %
    uint256 public constant MAX_V2_PATH = 4; // tokens
    uint256 public constant MAX_V3_HOPS = 3;
    uint256 private constant BPS = 10_000;
    uint256 private constant V3_ADDR = 20;
    uint256 private constant V3_HOP = 23; // address + uint24 fee

    // ERC-20 selectors the vault inspects itself
    bytes4 private constant SEL_TRANSFER = 0xa9059cbb;
    bytes4 private constant SEL_TRANSFER_FROM = 0x23b872dd;
    bytes4 private constant SEL_APPROVE = 0x095ea7b3;
    bytes4 private constant SEL_INCREASE_ALLOWANCE = 0x39509351;
    bytes4 private constant SEL_SET_APPROVAL_FOR_ALL = 0xa22cb465;

    // V2 router
    bytes4 private constant SWAP_EXACT_TOKENS_FOR_TOKENS = 0x38ed1739;
    bytes4 private constant SWAP_TOKENS_FOR_EXACT_TOKENS = 0x8803dbee;
    bytes4 private constant SWAP_EXACT_ETH_FOR_TOKENS = 0x7ff36ab5;
    bytes4 private constant SWAP_TOKENS_FOR_EXACT_ETH = 0x4a25d94a;
    bytes4 private constant SWAP_EXACT_TOKENS_FOR_ETH = 0x18cbafe5;
    bytes4 private constant SWAP_ETH_FOR_EXACT_TOKENS = 0xfb3bdb41;
    // V3 SwapRouter
    bytes4 private constant EXACT_INPUT_SINGLE = 0x414bf389;
    bytes4 private constant EXACT_INPUT = 0xc04b8d59;
    bytes4 private constant EXACT_OUTPUT_SINGLE = 0xdb3e2198;
    bytes4 private constant EXACT_OUTPUT = 0xf28c0498;

    address public immutable wrappedNative;
    uint256 public immutable maxSlippageBps;
    uint256 public immutable maxDeadline;

    mapping(address => RouterKind) public routerKind;
    mapping(address => TokenConfig) private _tokens;
    address[] private _routerList;
    address[] private _tokenList;

    mapping(bytes32 => Pending[]) private _pending;

    error BadConfig();
    error UnsupportedCall(address target, bytes4 selector);
    error ApproveToNonRouter(address spender);
    error TokenNotAllowed(address token);
    error RecipientNotVault(address recipient);
    error BadDeadline(uint256 deadline);
    error BadPath();
    error BadAmount();
    error NativeNotAllowed();
    error AmountTooLarge(address token, uint256 amount, uint256 max);
    error PriceTooLow(uint256 minimumOut, uint256 required);
    error PriceTooHigh(uint256 maximumIn, uint256 allowed);
    error StalePrice(address token);
    error BadPrice(address token);
    error BalanceCheckFailed(address asset, int256 actual, int256 required);

    constructor(
        address wrappedNative_,
        uint256 maxSlippageBps_,
        uint256 maxDeadline_,
        RouterInit[] memory routers_,
        TokenInit[] memory tokens_
    ) {
        if (maxSlippageBps_ == 0 || maxSlippageBps_ > MAX_SLIPPAGE_BPS) revert BadConfig();
        if (maxDeadline_ < 30 || maxDeadline_ > 1 days) revert BadConfig();
        if (routers_.length == 0 || tokens_.length < 2) revert BadConfig();
        maxSlippageBps = maxSlippageBps_;
        maxDeadline = maxDeadline_;
        wrappedNative = wrappedNative_;

        for (uint256 i = 0; i < routers_.length; i++) {
            RouterInit memory r = routers_[i];
            if (r.router.code.length == 0 || r.kind == RouterKind.None || routerKind[r.router] != RouterKind.None) {
                revert BadConfig();
            }
            routerKind[r.router] = r.kind;
            _routerList.push(r.router);
        }
        for (uint256 i = 0; i < tokens_.length; i++) {
            TokenInit memory t = tokens_[i];
            if (
                t.token.code.length == 0 || t.feed.code.length == 0 || _tokens[t.token].feed != address(0)
                    || routerKind[t.token] != RouterKind.None || t.maxAge == 0 || t.maxAmountIn == 0
                    || t.maxPrice == 0 || t.minPrice >= t.maxPrice
            ) revert BadConfig();
            uint8 td = IERC20Decimals(t.token).decimals();
            uint8 fd = IChainlinkFeed(t.feed).decimals();
            if (td > 24 || fd > 18) revert BadConfig();
            _tokens[t.token] = TokenConfig(t.feed, td, fd, t.maxAge, t.maxAmountIn, t.minPrice, t.maxPrice);
            _tokenList.push(t.token);
        }
        // native swaps are priced through the wrapped native token
        if (wrappedNative_ != address(0) && _tokens[wrappedNative_].feed == address(0)) revert BadConfig();
    }

    // ------------------------------------------------------------------ views

    function routers() external view returns (address[] memory) {
        return _routerList;
    }

    function tokens() external view returns (address[] memory) {
        return _tokenList;
    }

    function tokenConfig(address token) external view returns (TokenConfig memory) {
        return _tokens[token];
    }

    /// @notice Fair price of `token` in 18 decimals of the feeds' quote currency (reverts if unusable).
    function price(address token) external view returns (uint256) {
        return _price(token);
    }

    /// @notice Smallest acceptable output of an exact-input swap right now.
    function minimumOut(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256) {
        return Math.mulDiv(_fairOut(tokenIn, tokenOut, amountIn), BPS - maxSlippageBps, BPS);
    }

    /// @notice Largest acceptable input of an exact-output swap right now.
    function maximumIn(address tokenIn, address tokenOut, uint256 amountOut) external view returns (uint256) {
        return Math.mulDiv(_fairOut(tokenOut, tokenIn, amountOut), BPS + maxSlippageBps, BPS);
    }

    // ------------------------------------------------------------------ guard hooks

    function validate(uint256, address, address, address target, uint256 value, bytes calldata data) external {
        _validate(msg.sender, msg.sender, target, value, data);
    }

    function validateFor(address vault, uint256, address, address, address target, uint256 value, bytes calldata data)
        external
    {
        _validate(msg.sender, vault, target, value, data);
    }

    function afterBatch(uint256) external {
        _afterBatch(msg.sender, msg.sender);
    }

    function afterBatchFor(address vault, uint256) external {
        _afterBatch(msg.sender, vault);
    }

    // ------------------------------------------------------------------ rules

    function _validate(address caller, address vault, address target, uint256 value, bytes calldata data) internal {
        RouterKind kind = routerKind[target];
        if (kind != RouterKind.None) {
            Swap memory s = kind == RouterKind.V2 ? _decodeV2(target, value, data) : _decodeV3(target, value, data);
            _checkSwap(vault, s);
            if (_postCheckEnabled(vault)) _record(caller, vault, s);
            return;
        }
        if (data.length < 4) return; // plain native transfer: the vault checks the destination and limits
        bytes4 sel = bytes4(data[:4]);
        if (sel == SEL_TRANSFER || sel == SEL_TRANSFER_FROM || sel == SEL_SET_APPROVAL_FOR_ALL) return;
        if (sel == SEL_APPROVE || sel == SEL_INCREASE_ALLOWANCE) {
            (address spender, uint256 amount) = abi.decode(data[4:], (address, uint256));
            if (amount == 0) return; // resetting an allowance is always safe
            if (routerKind[spender] == RouterKind.None) revert ApproveToNonRouter(spender);
            if (_tokens[target].feed == address(0)) revert TokenNotAllowed(target);
            return;
        }
        revert UnsupportedCall(target, sel);
    }

    // slither-disable-start timestamp
    // timestamp: swap deadlines and feed staleness are minutes to hours; validator skew is irrelevant.
    function _checkSwap(address vault, Swap memory s) internal view {
        if (s.recipient != vault) revert RecipientNotVault(s.recipient);
        if (s.deadline < block.timestamp || s.deadline > block.timestamp + maxDeadline) revert BadDeadline(s.deadline);
        if (s.amount == 0 || s.limit == 0) revert BadAmount();

        if (s.exactIn) {
            _requireMaxIn(s.tokenIn, s.amount);
            uint256 required = Math.mulDiv(_fairOut(s.tokenIn, s.tokenOut, s.amount), BPS - maxSlippageBps, BPS);
            if (s.limit < required) revert PriceTooLow(s.limit, required);
        } else {
            _requireMaxIn(s.tokenIn, s.limit);
            uint256 allowed = Math.mulDiv(_fairOut(s.tokenOut, s.tokenIn, s.amount), BPS + maxSlippageBps, BPS);
            if (s.limit > allowed) revert PriceTooHigh(s.limit, allowed);
        }
    }
    // slither-disable-end timestamp

    function _requireMaxIn(address token, uint256 amount) internal view {
        uint256 max = _tokens[token].maxAmountIn;
        if (amount > max) revert AmountTooLarge(token, amount, max);
    }

    /// @dev Value of `amountIn` of `tokenIn`, expressed in `tokenOut`, at feed prices.
    function _fairOut(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        uint256 value = Math.mulDiv(amountIn, _price(tokenIn), 10 ** _tokens[tokenIn].tokenDecimals);
        return Math.mulDiv(value, 10 ** _tokens[tokenOut].tokenDecimals, _price(tokenOut));
    }

    // slither-disable-start timestamp
    // timestamp: feed staleness is measured in minutes to hours.
    function _price(address token) internal view returns (uint256) {
        TokenConfig memory t = _tokens[token];
        if (t.feed == address(0)) revert TokenNotAllowed(token);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkFeed(t.feed).latestRoundData();
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > t.maxAge) {
            revert StalePrice(token);
        }
        if (answeredInRound < roundId) revert StalePrice(token);
        if (answer <= 0) revert BadPrice(token);
        uint256 p = uint256(answer);
        if (p < t.minPrice || p > t.maxPrice) revert BadPrice(token);
        return p * 10 ** (18 - t.feedDecimals);
    }
    // slither-disable-end timestamp

    // ------------------------------------------------------------------ decoding

    function _decodeV2(address router, uint256 value, bytes calldata data) internal view returns (Swap memory s) {
        if (data.length < 4) revert UnsupportedCall(router, bytes4(0));
        bytes4 sel = bytes4(data[:4]);
        address[] memory path;
        bool nativeIn;
        bool nativeOut;
        if (sel == SWAP_EXACT_TOKENS_FOR_TOKENS || sel == SWAP_EXACT_TOKENS_FOR_ETH) {
            (s.amount, s.limit, path, s.recipient, s.deadline) =
                abi.decode(data[4:], (uint256, uint256, address[], address, uint256));
            s.exactIn = true;
            nativeOut = sel == SWAP_EXACT_TOKENS_FOR_ETH;
        } else if (sel == SWAP_TOKENS_FOR_EXACT_TOKENS || sel == SWAP_TOKENS_FOR_EXACT_ETH) {
            (s.amount, s.limit, path, s.recipient, s.deadline) =
                abi.decode(data[4:], (uint256, uint256, address[], address, uint256));
            nativeOut = sel == SWAP_TOKENS_FOR_EXACT_ETH;
        } else if (sel == SWAP_EXACT_ETH_FOR_TOKENS) {
            (s.limit, path, s.recipient, s.deadline) = abi.decode(data[4:], (uint256, address[], address, uint256));
            s.amount = value;
            s.exactIn = true;
            nativeIn = true;
        } else if (sel == SWAP_ETH_FOR_EXACT_TOKENS) {
            (s.amount, path, s.recipient, s.deadline) = abi.decode(data[4:], (uint256, address[], address, uint256));
            s.limit = value;
            nativeIn = true;
        } else {
            revert UnsupportedCall(router, sel);
        }
        if (!nativeIn && value != 0) revert NativeNotAllowed();

        uint256 n = path.length;
        if (n < 2 || n > MAX_V2_PATH) revert BadPath();
        for (uint256 i = 0; i < n; i++) {
            if (_tokens[path[i]].feed == address(0)) revert TokenNotAllowed(path[i]);
        }
        s.tokenIn = path[0];
        s.tokenOut = path[n - 1];
        s.assetIn = s.tokenIn;
        s.assetOut = s.tokenOut;
        if (nativeIn) {
            if (wrappedNative == address(0) || s.tokenIn != wrappedNative) revert BadPath();
            s.assetIn = NATIVE;
        }
        if (nativeOut) {
            if (wrappedNative == address(0) || s.tokenOut != wrappedNative) revert BadPath();
            s.assetOut = NATIVE;
        }
    }

    function _decodeV3(address router, uint256 value, bytes calldata data) internal view returns (Swap memory s) {
        if (data.length < 4) revert UnsupportedCall(router, bytes4(0));
        if (value != 0) revert NativeNotAllowed(); // V3: wrap first; no refunds left in the router
        bytes4 sel = bytes4(data[:4]);
        if (sel == EXACT_INPUT_SINGLE) {
            ExactInputSingleParams memory p = abi.decode(data[4:], (ExactInputSingleParams));
            (s.tokenIn, s.tokenOut, s.recipient, s.deadline) = (p.tokenIn, p.tokenOut, p.recipient, p.deadline);
            (s.amount, s.limit, s.exactIn) = (p.amountIn, p.amountOutMinimum, true);
            _requireListed(p.tokenIn);
            _requireListed(p.tokenOut);
        } else if (sel == EXACT_OUTPUT_SINGLE) {
            ExactOutputSingleParams memory p = abi.decode(data[4:], (ExactOutputSingleParams));
            (s.tokenIn, s.tokenOut, s.recipient, s.deadline) = (p.tokenIn, p.tokenOut, p.recipient, p.deadline);
            (s.amount, s.limit) = (p.amountOut, p.amountInMaximum);
            _requireListed(p.tokenIn);
            _requireListed(p.tokenOut);
        } else if (sel == EXACT_INPUT) {
            ExactInputParams memory p = abi.decode(data[4:], (ExactInputParams));
            (s.tokenIn, s.tokenOut) = _v3Path(p.path); // first token is paid in
            (s.recipient, s.deadline, s.amount, s.limit, s.exactIn) =
                (p.recipient, p.deadline, p.amountIn, p.amountOutMinimum, true);
        } else if (sel == EXACT_OUTPUT) {
            ExactOutputParams memory p = abi.decode(data[4:], (ExactOutputParams));
            (s.tokenOut, s.tokenIn) = _v3Path(p.path); // exact-output paths are encoded in reverse
            (s.recipient, s.deadline, s.amount, s.limit) = (p.recipient, p.deadline, p.amountOut, p.amountInMaximum);
        } else {
            revert UnsupportedCall(router, sel);
        }
        s.assetIn = s.tokenIn;
        s.assetOut = s.tokenOut;
    }

    /// @dev V3 path: token (20) | fee (3) | token (20) | ... ; every token must be listed.
    function _v3Path(bytes memory path) internal view returns (address first, address last) {
        uint256 len = path.length;
        if (len < V3_ADDR + V3_HOP || (len - V3_ADDR) % V3_HOP != 0) revert BadPath();
        uint256 hops = (len - V3_ADDR) / V3_HOP;
        if (hops > MAX_V3_HOPS) revert BadPath();
        for (uint256 i = 0; i <= hops; i++) {
            address t = _addressAt(path, i * V3_HOP);
            _requireListed(t);
            if (i == 0) first = t;
            if (i == hops) last = t;
        }
    }

    function _addressAt(bytes memory b, uint256 offset) internal pure returns (address a) {
        // offset + 20 <= b.length is guaranteed by the caller's length check
        assembly ("memory-safe") {
            a := shr(96, mload(add(add(b, 32), offset)))
        }
    }

    function _requireListed(address token) internal view {
        if (_tokens[token].feed == address(0)) revert TokenNotAllowed(token);
    }

    // ------------------------------------------------------------------ after-batch balance check

    /// @dev Only vaults that call `afterBatch` get per-batch state; older vaults rely on the pre-checks.
    function _postCheckEnabled(address vault) internal view returns (bool) {
        return IVersionedVault(vault).vaultVersion() >= POST_CHECK_FROM_VERSION;
    }

    function _key(address caller, address vault) internal pure returns (bytes32) {
        return keccak256(abi.encode(caller, vault));
    }

    function _record(address caller, address vault, Swap memory s) internal {
        Pending[] storage list = _pending[_key(caller, vault)];
        uint256 maxIn = s.exactIn ? s.amount : s.limit;
        uint256 minOut = s.exactIn ? s.limit : s.amount;
        _add(list, vault, s.assetIn, -maxIn.toInt256());
        _add(list, vault, s.assetOut, minOut.toInt256());
    }

    function _add(Pending[] storage list, address vault, address asset, int256 delta) internal {
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            if (list[i].asset == asset) {
                list[i].minDelta += delta;
                return;
            }
        }
        list.push(Pending(asset, _balance(asset, vault), delta));
    }

    // slither-disable-start calls-loop
    // calls-loop: one balance read per asset touched by the batch's swaps (bounded by the vault's MAX_CALLS).
    function _afterBatch(address caller, address vault) internal {
        bytes32 key = _key(caller, vault);
        Pending[] storage list = _pending[key];
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            Pending memory p = list[i];
            int256 actual = _balance(p.asset, vault).toInt256() - p.before.toInt256();
            if (actual < p.minDelta) revert BalanceCheckFailed(p.asset, actual, p.minDelta);
        }
        delete _pending[key];
    }

    function _balance(address asset, address vault) internal view returns (uint256) {
        if (asset == NATIVE) return vault.balance;
        return IERC20Decimals(asset).balanceOf(vault);
    }
    // slither-disable-end calls-loop
}
