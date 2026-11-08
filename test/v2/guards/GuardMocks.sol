// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// ERC-20 with any decimals; anyone can mint (tests only).
contract DecToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory sym, uint8 dec) ERC20(sym, sym) {
        _dec = dec;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Chainlink-style feed whose answer and timing the test controls.
contract MockFeed {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;

    constructor(uint8 dec, int256 answer_) {
        decimals = dec;
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function set(int256 answer_) external {
        answer = answer_;
        updatedAt = block.timestamp;
        roundId++;
        answeredInRound = roundId;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function setRounds(uint80 r, uint80 answered) external {
        roundId = r;
        answeredInRound = answered;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

/// Stand-in for a vault when a guard is called directly.
contract MockVersionedVault {
    uint64 public vaultVersion;

    constructor(uint64 v) {
        vaultVersion = v;
    }

    receive() external payable {}
}

/// Shared pricing for the mock routers: out = in * rate / 1e18, minus `shortBps` delivered (to model a
/// malicious router or a token that starts charging a transfer tax).
abstract contract RateBook {
    mapping(address => mapping(address => uint256)) public rate; // 1e18-scaled, tokenIn -> tokenOut
    uint256 public shortBps;
    address public immutable wrapped;

    constructor(address wrapped_) {
        wrapped = wrapped_;
    }

    function setRate(address a, address b, uint256 r) external {
        rate[a][b] = r;
    }

    function setShortBps(uint256 bps) external {
        shortBps = bps;
    }

    function _quoteOut(address a, address b, uint256 amountIn) internal view returns (uint256) {
        uint256 r = rate[a][b];
        require(r != 0, "no pool");
        return amountIn * r / 1e18;
    }

    function _quoteIn(address a, address b, uint256 amountOut) internal view returns (uint256) {
        uint256 r = rate[a][b];
        require(r != 0, "no pool");
        return (amountOut * 1e18 + r - 1) / r;
    }

    function _deliver(address token, address to, uint256 amount) internal {
        uint256 sent = amount - amount * shortBps / 10_000;
        if (token == address(0)) {
            (bool ok,) = to.call{value: sent}("");
            require(ok, "native send");
        } else {
            DecToken(token).mint(to, sent);
        }
    }

    function _pull(address token, address from, uint256 amount) internal {
        require(ERC20(token).transferFrom(from, address(this), amount), "pull");
    }
}

/// Uniswap / PancakeSwap V2-style router over the rate book (tokens are minted on the way out).
contract MockV2Router is RateBook {
    constructor(address wrapped_) RateBook(wrapped_) {}

    receive() external payable {}

    function _pathOut(address[] calldata path, uint256 amountIn) internal view returns (uint256 out) {
        out = amountIn;
        for (uint256 i = 0; i + 1 < path.length; i++) {
            out = _quoteOut(path[i], path[i + 1], out);
        }
    }

    function _pathIn(address[] calldata path, uint256 amountOut) internal view returns (uint256 inAmt) {
        inAmt = amountOut;
        for (uint256 i = path.length - 1; i > 0; i--) {
            inAmt = _quoteIn(path[i - 1], path[i], inAmt);
        }
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256 minOut, address[] calldata path, address to, uint256 dl)
        external
        returns (uint256[] memory)
    {
        require(dl >= block.timestamp, "expired");
        uint256 out = _pathOut(path, amountIn);
        require(out >= minOut, "INSUFFICIENT_OUTPUT_AMOUNT");
        _pull(path[0], msg.sender, amountIn);
        _deliver(path[path.length - 1], to, out);
        return new uint256[](0);
    }

    function swapTokensForExactTokens(uint256 amountOut, uint256 maxIn, address[] calldata path, address to, uint256 dl)
        external
        returns (uint256[] memory)
    {
        require(dl >= block.timestamp, "expired");
        uint256 inAmt = _pathIn(path, amountOut);
        require(inAmt <= maxIn, "EXCESSIVE_INPUT_AMOUNT");
        _pull(path[0], msg.sender, inAmt);
        _deliver(path[path.length - 1], to, amountOut);
        return new uint256[](0);
    }

    function swapExactETHForTokens(uint256 minOut, address[] calldata path, address to, uint256 dl)
        external
        payable
        returns (uint256[] memory)
    {
        require(dl >= block.timestamp, "expired");
        require(path[0] == wrapped, "INVALID_PATH");
        uint256 out = _pathOut(path, msg.value);
        require(out >= minOut, "INSUFFICIENT_OUTPUT_AMOUNT");
        _deliver(path[path.length - 1], to, out);
        return new uint256[](0);
    }

    function swapETHForExactTokens(uint256 amountOut, address[] calldata path, address to, uint256 dl)
        external
        payable
        returns (uint256[] memory)
    {
        require(dl >= block.timestamp, "expired");
        require(path[0] == wrapped, "INVALID_PATH");
        uint256 inAmt = _pathIn(path, amountOut);
        require(inAmt <= msg.value, "EXCESSIVE_INPUT_AMOUNT");
        _deliver(path[path.length - 1], to, amountOut);
        if (msg.value > inAmt) {
            (bool ok,) = msg.sender.call{value: msg.value - inAmt}("");
            require(ok, "refund");
        }
        return new uint256[](0);
    }

    function swapExactTokensForETH(uint256 amountIn, uint256 minOut, address[] calldata path, address to, uint256 dl)
        external
        returns (uint256[] memory)
    {
        require(dl >= block.timestamp, "expired");
        require(path[path.length - 1] == wrapped, "INVALID_PATH");
        uint256 out = _pathOut(path, amountIn);
        require(out >= minOut, "INSUFFICIENT_OUTPUT_AMOUNT");
        _pull(path[0], msg.sender, amountIn);
        _deliver(address(0), to, out);
        return new uint256[](0);
    }

    function swapTokensForExactETH(uint256 amountOut, uint256 maxIn, address[] calldata path, address to, uint256 dl)
        external
        returns (uint256[] memory)
    {
        require(dl >= block.timestamp, "expired");
        require(path[path.length - 1] == wrapped, "INVALID_PATH");
        uint256 inAmt = _pathIn(path, amountOut);
        require(inAmt <= maxIn, "EXCESSIVE_INPUT_AMOUNT");
        _pull(path[0], msg.sender, inAmt);
        _deliver(address(0), to, amountOut);
        return new uint256[](0);
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 minOut,
        address[] calldata path,
        address to,
        uint256 dl
    ) external {
        require(dl >= block.timestamp, "expired");
        uint256 out = _pathOut(path, amountIn);
        require(out >= minOut, "INSUFFICIENT_OUTPUT_AMOUNT");
        _pull(path[0], msg.sender, amountIn);
        _deliver(path[path.length - 1], to, out);
    }

    /// The classic bypass attempt: a batch of arbitrary router calls in one call.
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool ok, bytes memory r) = address(this).delegatecall(data[i]);
            require(ok, "multicall");
            results[i] = r;
        }
    }
}

/// Uniswap V3 SwapRouter-style router (deadline inside the params) over the rate book.
contract MockV3Router is RateBook {
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

    constructor(address wrapped_) RateBook(wrapped_) {}

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        require(p.deadline >= block.timestamp, "Transaction too old");
        out = _quoteOut(p.tokenIn, p.tokenOut, p.amountIn);
        require(out >= p.amountOutMinimum, "Too little received");
        _pull(p.tokenIn, msg.sender, p.amountIn);
        _deliver(p.tokenOut, p.recipient, out);
    }

    function exactOutputSingle(ExactOutputSingleParams calldata p) external payable returns (uint256 inAmt) {
        require(p.deadline >= block.timestamp, "Transaction too old");
        inAmt = _quoteIn(p.tokenIn, p.tokenOut, p.amountOut);
        require(inAmt <= p.amountInMaximum, "Too much requested");
        _pull(p.tokenIn, msg.sender, inAmt);
        _deliver(p.tokenOut, p.recipient, p.amountOut);
    }

    function exactInput(ExactInputParams calldata p) external payable returns (uint256 out) {
        require(p.deadline >= block.timestamp, "Transaction too old");
        address[] memory t = _tokens(p.path);
        out = p.amountIn;
        for (uint256 i = 0; i + 1 < t.length; i++) {
            out = _quoteOut(t[i], t[i + 1], out);
        }
        require(out >= p.amountOutMinimum, "Too little received");
        _pull(t[0], msg.sender, p.amountIn);
        _deliver(t[t.length - 1], p.recipient, out);
    }

    function exactOutput(ExactOutputParams calldata p) external payable returns (uint256 inAmt) {
        require(p.deadline >= block.timestamp, "Transaction too old");
        address[] memory t = _tokens(p.path); // reversed: t[0] = token out
        inAmt = p.amountOut;
        for (uint256 i = 0; i + 1 < t.length; i++) {
            inAmt = _quoteIn(t[i + 1], t[i], inAmt);
        }
        require(inAmt <= p.amountInMaximum, "Too much requested");
        _pull(t[t.length - 1], msg.sender, inAmt);
        _deliver(t[0], p.recipient, p.amountOut);
    }

    function _tokens(bytes memory path) internal pure returns (address[] memory t) {
        uint256 n = (path.length - 20) / 23 + 1;
        t = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 off = i * 23;
            address a;
            assembly {
                a := shr(96, mload(add(add(path, 32), off)))
            }
            t[i] = a;
        }
    }
}
