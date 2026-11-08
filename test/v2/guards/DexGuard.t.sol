// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {DexGuard} from "../../../contracts/v2/guards/DexGuard.sol";
import {DecToken, MockFeed, MockVersionedVault, MockV2Router, MockV3Router} from "./GuardMocks.sol";

/// DexGuard on its own: configuration rules, decoding, prices and the after-batch bookkeeping.
contract DexGuardUnitTest is Test {
    DecToken usdt;
    DecToken wbnb;
    DecToken cake;
    DecToken junk;
    MockFeed usdtFeed;
    MockFeed wbnbFeed;
    MockFeed cakeFeed;
    MockV2Router v2;
    MockV3Router v3;
    DexGuard guard;
    MockVersionedVault vault21; // calls afterBatch
    MockVersionedVault vault20; // pre-2.1: validate only

    function setUp() public {
        vm.warp(1_800_000_000);
        usdt = new DecToken("USDT", 6);
        wbnb = new DecToken("WBNB", 18);
        cake = new DecToken("CAKE", 18);
        junk = new DecToken("JUNK", 18);
        usdtFeed = new MockFeed(8, 1e8);
        wbnbFeed = new MockFeed(8, 600e8);
        cakeFeed = new MockFeed(18, 2e18);
        v2 = new MockV2Router(address(wbnb));
        v3 = new MockV3Router(address(wbnb));
        guard = new DexGuard(address(wbnb), 100, 10 minutes, _routers(), _tokens());
        vault21 = new MockVersionedVault(20_100);
        vault20 = new MockVersionedVault(20_000);
    }

    function _routers() internal view returns (DexGuard.RouterInit[] memory r) {
        r = new DexGuard.RouterInit[](2);
        r[0] = DexGuard.RouterInit(address(v2), DexGuard.RouterKind.V2);
        r[1] = DexGuard.RouterInit(address(v3), DexGuard.RouterKind.V3);
    }

    function _tokens() internal view returns (DexGuard.TokenInit[] memory t) {
        t = new DexGuard.TokenInit[](3);
        t[0] = DexGuard.TokenInit(address(usdt), address(usdtFeed), 1 days, 50_000e6, 0.5e8, 2e8);
        t[1] = DexGuard.TokenInit(address(wbnb), address(wbnbFeed), 1 hours, 100e18, 1e8, 100_000e8);
        t[2] = DexGuard.TokenInit(address(cake), address(cakeFeed), 1 hours, 100_000e18, 0.01e18, 1_000e18);
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _v2In(uint256 amountIn, uint256 minOut, address to) internal view returns (bytes memory) {
        return abi.encodeCall(
            MockV2Router.swapExactTokensForTokens,
            (amountIn, minOut, _path(address(usdt), address(wbnb)), to, block.timestamp + 60)
        );
    }

    function _call(address from, address target, uint256 value, bytes memory data) internal {
        vm.prank(from);
        guard.validate(1, address(0), address(0), target, value, data);
    }

    function _expectCall(address from, address target, uint256 value, bytes memory data, bytes memory err) internal {
        vm.expectRevert(err);
        vm.prank(from);
        guard.validate(1, address(0), address(0), target, value, data);
    }

    // ------------------------------------------------------------------ configuration

    function test_config_rejectsBadSetups() public {
        DexGuard.RouterInit[] memory r = _routers();
        DexGuard.TokenInit[] memory t = _tokens();
        vm.expectRevert(DexGuard.BadConfig.selector);
        new DexGuard(address(wbnb), 0, 10 minutes, r, t); // no slippage at all is not a usable setting
        vm.expectRevert(DexGuard.BadConfig.selector);
        new DexGuard(address(wbnb), 1_001, 10 minutes, r, t);
        vm.expectRevert(DexGuard.BadConfig.selector);
        new DexGuard(address(wbnb), 100, 2 days, r, t);
        vm.expectRevert(DexGuard.BadConfig.selector);
        new DexGuard(address(wbnb), 100, 10 minutes, new DexGuard.RouterInit[](0), t);

        r[1].router = address(v2); // duplicate router
        vm.expectRevert(DexGuard.BadConfig.selector);
        new DexGuard(address(wbnb), 100, 10 minutes, r, t);
        r = _routers();
        r[1].router = makeAddr("eoa"); // no code
        vm.expectRevert(DexGuard.BadConfig.selector);
        new DexGuard(address(wbnb), 100, 10 minutes, r, t);
        r = _routers();

        t[2].token = address(usdt); // duplicate token
        vm.expectRevert(DexGuard.BadConfig.selector);
        new DexGuard(address(wbnb), 100, 10 minutes, r, t);
        t = _tokens();
        t[2].feed = makeAddr("noFeed");
        vm.expectRevert(DexGuard.BadConfig.selector);
        new DexGuard(address(wbnb), 100, 10 minutes, r, t);
        t = _tokens();
        t[2].minPrice = t[2].maxPrice;
        vm.expectRevert(DexGuard.BadConfig.selector);
        new DexGuard(address(wbnb), 100, 10 minutes, r, t);
        t = _tokens();
        t[2].maxAmountIn = 0;
        vm.expectRevert(DexGuard.BadConfig.selector);
        new DexGuard(address(wbnb), 100, 10 minutes, r, t);
        t = _tokens();
        t[2].token = address(v2); // a router cannot be a token
        vm.expectRevert(DexGuard.BadConfig.selector);
        new DexGuard(address(wbnb), 100, 10 minutes, r, t);
        t = _tokens();
        vm.expectRevert(DexGuard.BadConfig.selector);
        new DexGuard(address(junk), 100, 10 minutes, r, t); // wrapped native must be priced
        t[2].feed = address(new MockFeed(19, 1)); // feed decimals > 18
        vm.expectRevert(DexGuard.BadConfig.selector);
        new DexGuard(address(wbnb), 100, 10 minutes, r, t);
    }

    function test_config_views() public view {
        assertEq(guard.routers().length, 2);
        assertEq(guard.tokens().length, 3);
        assertEq(guard.tokenConfig(address(usdt)).tokenDecimals, 6);
        assertEq(guard.tokenConfig(address(cake)).feedDecimals, 18);
        assertEq(guard.price(address(wbnb)), 600e18);
        assertEq(guard.price(address(cake)), 2e18);
        // 6,000 USDT -> 10 WBNB fair, 1 % slippage
        assertEq(guard.minimumOut(address(usdt), address(wbnb), 6_000e6), 9.9e18);
        assertEq(guard.maximumIn(address(usdt), address(wbnb), 10e18), 6_060e6);
    }

    // ------------------------------------------------------------------ prices

    function test_price_staleRoundsFutureAndZero() public {
        wbnbFeed.setRounds(5, 4); // answer carried over from an older round
        vm.expectRevert(abi.encodeWithSelector(DexGuard.StalePrice.selector, address(wbnb)));
        guard.price(address(wbnb));
        wbnbFeed.set(600e8);
        wbnbFeed.setUpdatedAt(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(DexGuard.StalePrice.selector, address(wbnb)));
        guard.price(address(wbnb));
        wbnbFeed.setUpdatedAt(0);
        vm.expectRevert(abi.encodeWithSelector(DexGuard.StalePrice.selector, address(wbnb)));
        guard.price(address(wbnb));
        wbnbFeed.set(0);
        vm.expectRevert(abi.encodeWithSelector(DexGuard.BadPrice.selector, address(wbnb)));
        guard.price(address(wbnb));
        wbnbFeed.set(0.5e8); // below the sanity bound
        vm.expectRevert(abi.encodeWithSelector(DexGuard.BadPrice.selector, address(wbnb)));
        guard.price(address(wbnb));
        vm.expectRevert(abi.encodeWithSelector(DexGuard.TokenNotAllowed.selector, address(junk)));
        guard.price(address(junk));
    }

    // ------------------------------------------------------------------ decoding

    function test_v2_pathAndNativeRules() public {
        address v = address(vault21);
        address[] memory longPath = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            longPath[i] = i % 2 == 0 ? address(usdt) : address(wbnb);
        }
        bytes memory d = abi.encodeCall(
            MockV2Router.swapExactTokensForTokens, (1e6, 1, longPath, v, block.timestamp + 60)
        );
        _expectCall(v, address(v2), 0, d, abi.encodeWithSelector(DexGuard.BadPath.selector));

        d = abi.encodeCall(MockV2Router.swapExactTokensForTokens, (1e6, 1, new address[](1), v, block.timestamp + 60));
        _expectCall(v, address(v2), 0, d, abi.encodeWithSelector(DexGuard.BadPath.selector));

        // native in must start at the wrapped native token
        d = abi.encodeCall(
            MockV2Router.swapExactETHForTokens, (1, _path(address(usdt), address(cake)), v, block.timestamp + 60)
        );
        _expectCall(v, address(v2), 1 ether, d, abi.encodeWithSelector(DexGuard.BadPath.selector));
        // native out must end at the wrapped native token
        d = abi.encodeCall(
            MockV2Router.swapExactTokensForETH, (1e6, 1, _path(address(usdt), address(cake)), v, block.timestamp + 60)
        );
        _expectCall(v, address(v2), 0, d, abi.encodeWithSelector(DexGuard.BadPath.selector));
        // no native value on a token-in swap
        _expectCall(v, address(v2), 1, _v2In(600e6, 0.99e18, v), abi.encodeWithSelector(DexGuard.NativeNotAllowed.selector));
        // zero amounts
        _expectCall(v, address(v2), 0, _v2In(0, 1, v), abi.encodeWithSelector(DexGuard.BadAmount.selector));
        // expired deadline
        d = abi.encodeCall(
            MockV2Router.swapExactTokensForTokens, (600e6, 0.99e18, _path(address(usdt), address(wbnb)), v, block.timestamp - 1)
        );
        _expectCall(v, address(v2), 0, d, abi.encodeWithSelector(DexGuard.BadDeadline.selector, block.timestamp - 1));
        // short calldata to a router
        _expectCall(v, address(v2), 0, hex"0102", abi.encodeWithSelector(DexGuard.UnsupportedCall.selector, address(v2), bytes4(0)));
    }

    function test_v3_rules() public {
        address v = address(vault21);
        bytes memory d = abi.encodeCall(
            MockV3Router.exactInputSingle,
            (MockV3Router.ExactInputSingleParams(address(usdt), address(junk), 500, v, block.timestamp + 60, 1e6, 1, 0))
        );
        _expectCall(v, address(v3), 0, d, abi.encodeWithSelector(DexGuard.TokenNotAllowed.selector, address(junk)));

        d = abi.encodeCall(
            MockV3Router.exactInputSingle,
            (MockV3Router.ExactInputSingleParams(address(usdt), address(wbnb), 500, v, block.timestamp + 60, 600e6, 0.99e18, 0))
        );
        _expectCall(v, address(v3), 1 wei, d, abi.encodeWithSelector(DexGuard.NativeNotAllowed.selector));
        _call(v, address(v3), 0, d);

        bytes memory badPath = abi.encodePacked(address(usdt), uint24(500), address(wbnb), uint8(1));
        d = abi.encodeCall(
            MockV3Router.exactInput, (MockV3Router.ExactInputParams(badPath, v, block.timestamp + 60, 1e6, 1))
        );
        _expectCall(v, address(v3), 0, d, abi.encodeWithSelector(DexGuard.BadPath.selector));

        bytes memory fourHops = abi.encodePacked(
            address(usdt), uint24(500), address(wbnb), uint24(500), address(cake), uint24(500), address(wbnb)
        );
        fourHops = abi.encodePacked(fourHops, uint24(500), address(usdt));
        d = abi.encodeCall(
            MockV3Router.exactInput, (MockV3Router.ExactInputParams(fourHops, v, block.timestamp + 60, 1e6, 1))
        );
        _expectCall(v, address(v3), 0, d, abi.encodeWithSelector(DexGuard.BadPath.selector));

        bytes memory junkPath = abi.encodePacked(address(usdt), uint24(500), address(junk), uint24(500), address(wbnb));
        d = abi.encodeCall(
            MockV3Router.exactInput, (MockV3Router.ExactInputParams(junkPath, v, block.timestamp + 60, 1e6, 1))
        );
        _expectCall(v, address(v3), 0, d, abi.encodeWithSelector(DexGuard.TokenNotAllowed.selector, address(junk)));

        // exact-output single: overpay is refused, a fair maximum passes
        d = abi.encodeCall(
            MockV3Router.exactOutputSingle,
            (MockV3Router.ExactOutputSingleParams(address(usdt), address(wbnb), 500, v, block.timestamp + 60, 1e18, 700e6, 0))
        );
        _expectCall(v, address(v3), 0, d, abi.encodeWithSelector(DexGuard.PriceTooHigh.selector, 700e6, 606e6));
        d = abi.encodeCall(
            MockV3Router.exactOutputSingle,
            (MockV3Router.ExactOutputSingleParams(address(usdt), address(wbnb), 500, v, block.timestamp + 60, 1e18, 606e6, 0))
        );
        _call(v, address(v3), 0, d);
    }

    // ------------------------------------------------------------------ non-swap calls

    function test_otherCalls() public {
        address v = address(vault20);
        _call(v, address(usdt), 0, abi.encodeCall(IERC20.transfer, (makeAddr("x"), 1)));
        _call(v, address(usdt), 0, abi.encodeCall(IERC20.approve, (makeAddr("anyone"), 0))); // reset is fine
        _call(v, address(usdt), 0, abi.encodeCall(IERC20.approve, (address(v2), 1e6)));
        _call(v, makeAddr("payee"), 1 ether, ""); // plain native transfer
        _expectCall(
            v,
            address(junk),
            0,
            abi.encodeCall(IERC20.approve, (address(v2), 1e6)),
            abi.encodeWithSelector(DexGuard.TokenNotAllowed.selector, address(junk))
        );
        _expectCall(
            v,
            address(usdt),
            0,
            abi.encodeCall(IERC20.approve, (makeAddr("spender"), 1e6)),
            abi.encodeWithSelector(DexGuard.ApproveToNonRouter.selector, makeAddr("spender"))
        );
        // any other contract call: refused (fail closed)
        _expectCall(
            v,
            makeAddr("lending"),
            0,
            abi.encodeWithSignature("withdraw(address,uint256,address)", address(usdt), 1, v),
            abi.encodeWithSelector(DexGuard.UnsupportedCall.selector, makeAddr("lending"), bytes4(0x69328dec))
        );
    }

    // ------------------------------------------------------------------ after-batch bookkeeping

    function test_postCheck_onlyOnVault21AndPerCaller() public {
        // 2.0.x vault: validate only, nothing recorded, afterBatch has nothing to check
        _call(address(vault20), address(v2), 0, _v2In(600e6, 0.99e18, address(vault20)));
        vm.prank(address(vault20));
        guard.afterBatch(1);

        // 2.1.0 vault: the swap is recorded; nothing arrived, so afterBatch refuses
        _call(address(vault21), address(v2), 0, _v2In(600e6, 0.99e18, address(vault21)));
        vm.prank(address(vault21));
        vm.expectPartialRevert(DexGuard.BalanceCheckFailed.selector);
        guard.afterBatch(1);

        // a stranger writing "for" a vault only fills its own slot, never the vault's
        MockVersionedVault fresh = new MockVersionedVault(20_100);
        vm.prank(makeAddr("stranger"));
        guard.validateFor(address(fresh), 1, address(0), address(0), address(v2), 0, _v2In(600e6, 0.99e18, address(fresh)));
        vm.prank(address(fresh));
        guard.afterBatch(1); // the vault's own slot is empty: passes
    }

    function test_postCheck_passesWhenTheSwapDelivers() public {
        _call(address(vault21), address(v2), 0, _v2In(600e6, 0.99e18, address(vault21)));
        wbnb.mint(address(vault21), 0.99e18); // the swap's output arrived
        vm.prank(address(vault21));
        guard.afterBatch(1);
    }

    // ------------------------------------------------------------------ fuzz

    /// The minimum-out rule is exactly "fair value minus slippage", at any price.
    function testFuzz_minimumOutBoundary(uint256 amountIn, uint256 bnbPrice, uint256 minOut) public {
        amountIn = bound(amountIn, 1e6, 50_000e6);
        bnbPrice = bound(bnbPrice, 1e8, 100_000e8);
        wbnbFeed.set(int256(bnbPrice));
        // the guard rounds a minimum output up (in the vault's favour)
        uint256 fair = Math.mulDiv(Math.mulDiv(amountIn, 1e18, 1e6, Math.Rounding.Ceil), 1e18, bnbPrice * 1e10, Math.Rounding.Ceil);
        uint256 required = Math.mulDiv(fair, 9_900, 10_000, Math.Rounding.Ceil);
        minOut = bound(minOut, 1, fair * 2 + 1);
        bytes memory d = _v2In(amountIn, minOut, address(vault20));
        if (minOut < required) {
            _expectCall(address(vault20), address(v2), 0, d, abi.encodeWithSelector(DexGuard.PriceTooLow.selector, minOut, required));
        } else {
            _call(address(vault20), address(v2), 0, d);
        }
    }

    /// Output to anyone but the vault is always refused.
    function testFuzz_recipientMustBeVault(address to) public {
        vm.assume(to != address(vault20));
        _expectCall(
            address(vault20),
            address(v2),
            0,
            _v2In(600e6, 0.99e18, to),
            abi.encodeWithSelector(DexGuard.RecipientNotVault.selector, to)
        );
    }

    /// A call to anything that is not a router, with a selector the vault does not inspect, is refused.
    function testFuzz_unknownCallsRefused(address target, bytes4 sel, bytes32 arg) public {
        vm.assume(target != address(v2) && target != address(v3));
        vm.assume(
            sel != IERC20.transfer.selector && sel != IERC20.transferFrom.selector && sel != IERC20.approve.selector
                && sel != bytes4(0x39509351) && sel != bytes4(0xa22cb465)
        );
        _expectCall(
            address(vault20),
            target,
            0,
            abi.encodePacked(sel, arg),
            abi.encodeWithSelector(DexGuard.UnsupportedCall.selector, target, sel)
        );
    }
}
