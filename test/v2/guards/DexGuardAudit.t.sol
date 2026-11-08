// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EPKVault} from "../../../contracts/v2/EPKVault.sol";
import {DexGuard} from "../../../contracts/v2/guards/DexGuard.sol";
import {GuardBase} from "./GuardBase.sol";
import {DecToken, MockFeed, MockV2Router, MockV3Router, MockVersionedVault} from "./GuardMocks.sol";

/// WBNB-style wrapped native token: sending native coin to it mints the same amount ("wrap").
contract MockWrapped is DecToken {
    constructor() DecToken("WBNB", 18) {}

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// V3 router that behaves like the real Uniswap / PancakeSwap V3 SwapRouter in the two places the
/// internal audit of 2026-11-08 attacked:
/// - `exactOutputSingle` with `sqrtPriceLimitX96 != 0`: the swap stops at the price limit, so the
///   router may deliver far less than `amountOut` while charging up to `amountInMaximum`
///   (modelled: it charges `amountInMaximum` and delivers 0.1 % of `amountOut`);
/// - `sweepToken`: anyone can take tokens that sit in the router (PeripheryPayments).
contract RealisticV3Router {
    function setRate(address, address, uint256) external {}

    function exactOutputSingle(MockV3Router.ExactOutputSingleParams calldata p) external payable returns (uint256) {
        require(p.deadline >= block.timestamp, "Transaction too old");
        uint256 delivered = p.sqrtPriceLimitX96 != 0 ? p.amountOut / 1000 : p.amountOut;
        require(IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountInMaximum), "pull");
        DecToken(p.tokenOut).mint(p.recipient, delivered);
        return p.amountInMaximum;
    }

    function sweepToken(address token, uint256 amountMinimum, address recipient) external payable {
        uint256 bal = IERC20(token).balanceOf(address(this));
        require(bal >= amountMinimum, "Insufficient token");
        if (bal > 0) require(IERC20(token).transfer(recipient, bal), "sweep");
    }
}

/// Attacks found by the internal audit of 2026-11-08, replayed against a real EPKVault 2.1.0 guarded by
/// DexGuard. Each test is written as "the attack must fail".
contract DexGuardAuditTest is GuardBase {
    function setUp() public {
        // the GuardBase market, but WBNB can be wrapped and the V3 router is the realistic one
        usdt = new DecToken("USDT", 6);
        wbnb = DecToken(address(new MockWrapped()));
        cake = new DecToken("CAKE", 18);
        junk = new DecToken("JUNK", 18);
        usdtFeed = new MockFeed(8, 1e8);
        wbnbFeed = new MockFeed(8, 600e8);
        cakeFeed = new MockFeed(18, 2e18);
        v2 = new MockV2Router(address(wbnb));
        v3 = MockV3Router(address(new RealisticV3Router()));
        vm.deal(address(v2), 1_000 ether);
        _setFairRates(9_970);
        _deployGuard();
        _deployVault();
        _setUpVault(address(guard));
    }

    function _timelocked(bytes memory data) internal {
        vm.prank(admin);
        vault.schedule(data, bytes32(0));
        vm.warp(block.timestamp + DELAY);
        vm.prank(admin);
        vault.executeScheduled(data, bytes32(0));
        // keep the feeds fresh after the warp
        usdtFeed.set(1e8);
        wbnbFeed.set(600e8);
        cakeFeed.set(2e18);
    }

    /// The owner allows wrapping BNB into WBNB (the guard's own advice for V3: "wrap first").
    function _allowWrapping() internal {
        _timelocked(abi.encodeCall(EPKVault.addDestination, (address(wbnb))));
        _timelocked(abi.encodeCall(EPKVault.setCall, (pid, address(wbnb), bytes4(0), true)));
    }

    function _v3ExactOutSingle(uint256 amountOut, uint256 maxIn, uint160 priceLimit) internal view returns (bytes memory) {
        return abi.encodeCall(
            MockV3Router.exactOutputSingle,
            (
                MockV3Router.ExactOutputSingleParams(
                    address(usdt), address(wbnb), 500, address(vault), _now() + 5 minutes, amountOut, maxIn, priceLimit
                )
            )
        );
    }

    /// F1: a V3 single-pool swap with a price limit can stop early. The guard priced the whole
    /// `amountOut`, the router charges up to `amountInMaximum` and delivers dust. Five wraps of the
    /// vault's own BNB top the WBNB balance up, so a pure balance check would not notice.
    function test_v3PriceLimitPartialFillIsRefused() public {
        _allowWrapping();
        uint256 maxIn = 30_300e6; // the guard's limit for 50 WBNB at $600 + 1 %
        EPKVault.Call[] memory c = new EPKVault.Call[](8);
        c[0] = EPKVault.Call(address(usdt), 0, abi.encodeCall(IERC20.approve, (address(v3), maxIn)));
        c[1] = EPKVault.Call(address(v3), 0, _v3ExactOutSingle(50e18, maxIn, 1));
        for (uint256 i = 0; i < 5; i++) {
            c[2 + i] = EPKVault.Call(address(wbnb), 9.99 ether, "");
        }
        c[7] = EPKVault.Call(address(usdt), 0, abi.encodeCall(IERC20.approve, (address(v3), 0)));
        uint256 usdtBefore = usdt.balanceOf(address(vault));
        _execFailsWith(pid, OP_PK, c, DexGuard.PriceLimitNotAllowed.selector);
        assertEq(usdt.balanceOf(address(vault)), usdtBefore);
    }

    /// F1 (second half): even without a price limit, a router that under-delivers must be caught after
    /// the batch, also when the vault wraps its own BNB into the same token in the same batch.
    function test_wrapCannotHideAShortSwap() public {
        _allowWrapping();
        v2.setShortBps(9_990); // the pool / router delivers only 0.1 %
        bytes memory swap = abi.encodeCall(
            MockV2Router.swapTokensForExactTokens,
            (50e18, 30_300e6, _path(address(usdt), address(wbnb)), address(vault), _now() + 5 minutes)
        );
        EPKVault.Call[] memory c = new EPKVault.Call[](8);
        c[0] = EPKVault.Call(address(usdt), 0, abi.encodeCall(IERC20.approve, (address(v2), 30_300e6)));
        c[1] = EPKVault.Call(address(v2), 0, swap);
        for (uint256 i = 0; i < 5; i++) {
            c[2 + i] = EPKVault.Call(address(wbnb), 9.99 ether, "");
        }
        c[7] = EPKVault.Call(address(usdt), 0, abi.encodeCall(IERC20.approve, (address(v2), 0)));
        _execFailsWith(pid, OP_PK, c, DexGuard.BalanceCheckFailed.selector);
    }

    /// A plain wrap on its own still works and the balance check accounts for it.
    function test_plainWrapStillWorks() public {
        _allowWrapping();
        uint256 before = wbnb.balanceOf(address(vault));
        _exec(pid, OP_PK, _one(address(wbnb), 1 ether, ""));
        assertEq(wbnb.balanceOf(address(vault)), before + 1 ether);
    }

    /// F2: routers are allowlisted destinations (they must be, to receive approvals), but tokens sent
    /// to a router can be swept by anyone (V3 `sweepToken`, V2 `removeLiquidity...SupportingFeeOnTransfer`).
    function test_transferToRouterIsRefused() public {
        bytes memory payRouter = abi.encodeCall(IERC20.transfer, (address(v3), 50_000e6));
        _execFailsWith(pid, OP_PK, _one(address(usdt), 0, payRouter), DexGuard.RecipientNotAllowed.selector);
        // had it gone through, this is all the attacker would need:
        vm.prank(attacker);
        RealisticV3Router(address(v3)).sweepToken(address(usdt), 0, attacker);
        assertEq(usdt.balanceOf(attacker), 0);
    }

    /// Same rule for transferFrom and for the wrapped native token (tokens sent there are lost), checked
    /// on the guard directly (this test vault's policy does not allow transferFrom).
    function test_transferFromToRouterIsRefused() public {
        MockVersionedVault v20 = new MockVersionedVault(20000);
        bytes memory toRouter = abi.encodeCall(IERC20.transferFrom, (address(v20), address(v2), 1e6));
        vm.prank(address(v20));
        vm.expectRevert(abi.encodeWithSelector(DexGuard.RecipientNotAllowed.selector, address(v2)));
        guard.validate(0, address(0), address(0), address(usdt), 0, toRouter);

        bytes memory toWrapped = abi.encodeCall(IERC20.transfer, (address(wbnb), 1e6));
        vm.prank(address(v20));
        vm.expectRevert(abi.encodeWithSelector(DexGuard.RecipientNotAllowed.selector, address(wbnb)));
        guard.validate(0, address(0), address(0), address(usdt), 0, toWrapped);
    }

    /// Ordinary payments to allowlisted people still pass the guard.
    function test_transferToFriendStillWorks() public {
        _exec(pid, OP_PK, _one(address(usdt), 0, abi.encodeCall(IERC20.transfer, (friend, 100e6))));
        assertEq(usdt.balanceOf(friend), 100e6);
    }

    /// F6a: minimum outputs round in the vault's favour, so a token with few decimals cannot lose a
    /// whole unit to rounding (a 0-decimal $1,000 token bought for $1,999 must return 2 units, not 1).
    function test_minimumOutRoundsUp() public {
        DecToken gold = new DecToken("GOLD", 0);
        MockFeed goldFeed = new MockFeed(8, 1_000e8);
        DexGuard.RouterInit[] memory r = new DexGuard.RouterInit[](1);
        r[0] = DexGuard.RouterInit(address(v2), DexGuard.RouterKind.V2);
        DexGuard.TokenInit[] memory t = new DexGuard.TokenInit[](2);
        t[0] = DexGuard.TokenInit(address(usdt), address(usdtFeed), 1 days, 50_000e6, 0.5e8, 2e8);
        t[1] = DexGuard.TokenInit(address(gold), address(goldFeed), 1 days, 1_000, 1e8, 100_000e8);
        DexGuard g = new DexGuard(address(0), SLIPPAGE_BPS, MAX_DEADLINE, r, t);
        assertEq(g.minimumOut(address(usdt), address(gold), 1_999e6), 2);

        MockVersionedVault v20 = new MockVersionedVault(20000); // a 2.0.x vault: pre-checks only
        bytes memory swap = abi.encodeCall(
            MockV2Router.swapExactTokensForTokens,
            (1_999e6, 1, _path(address(usdt), address(gold)), address(v20), _now() + 5 minutes)
        );
        vm.prank(address(v20));
        vm.expectRevert(abi.encodeWithSelector(DexGuard.PriceTooLow.selector, 1, 2));
        g.validate(0, address(0), address(0), address(v2), 0, swap);
    }
}
