// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EPKVault} from "../../../contracts/v2/EPKVault.sol";
import {DexGuard} from "../../../contracts/v2/guards/DexGuard.sol";
import {MockV2Router, MockV3Router} from "./GuardMocks.sol";
import {GuardBase} from "./GuardBase.sol";

/// DexGuard on a real EPKVault 2.1.0: allowed trades go through, every attack a compromised operator or
/// AI agent could sign is rejected on-chain, for ordinary policies and for agent sessions alike.
contract DexGuardVaultTest is GuardBase {
    function setUp() public {
        _deployMarket();
        _deployGuard();
        _deployVault();
        _setUpVault(address(guard));
    }

    // ================================================================== allowed trades

    function test_v2ExactInSwap() public {
        uint256 minOut = guard.minimumOut(address(usdt), address(wbnb), 6_000e6);
        uint256 before = wbnb.balanceOf(address(vault));
        _exec(pid, OP_PK, _v2ExactIn(address(usdt), address(wbnb), 6_000e6, minOut, address(vault)));
        assertApproxEqRel(wbnb.balanceOf(address(vault)) - before, 9.97e18, 1e9); // 10 WBNB minus the pool fee
        assertEq(usdt.allowance(address(vault), address(v2)), 0);
    }

    function test_v2NativeInAndOut() public {
        // 1 BNB -> USDT
        uint256 minOut = guard.minimumOut(address(wbnb), address(usdt), 1 ether);
        bytes memory d = abi.encodeCall(
            MockV2Router.swapExactETHForTokens, (minOut, _path(address(wbnb), address(usdt)), address(vault), _now() + 60)
        );
        uint256 u0 = usdt.balanceOf(address(vault));
        _exec(pid, OP_PK, _one(address(v2), 1 ether, d));
        assertEq(usdt.balanceOf(address(vault)) - u0, 598.2e6);

        // USDT -> BNB, exact output
        uint256 maxIn = guard.maximumIn(address(usdt), address(wbnb), 0.5 ether);
        d = abi.encodeCall(
            MockV2Router.swapTokensForExactETH,
            (0.5 ether, maxIn, _path(address(usdt), address(wbnb)), address(vault), _now() + 60)
        );
        uint256 n0 = address(vault).balance;
        _exec(pid, OP_PK, _approveSwap(address(usdt), address(v2), maxIn, 0, d));
        assertEq(address(vault).balance - n0, 0.5 ether);
    }

    function test_v3SingleMultiHopAndExactOutput() public {
        uint256 minOut = guard.minimumOut(address(usdt), address(cake), 1_000e6);
        bytes memory d = abi.encodeCall(
            MockV3Router.exactInputSingle,
            (MockV3Router.ExactInputSingleParams(
                    address(usdt), address(cake), 500, address(vault), _now() + 60, 1_000e6, minOut, 0
                ))
        );
        _exec(pid, OP_PK, _approveSwap(address(usdt), address(v3), 1_000e6, 0, d));

        // USDT -> WBNB -> CAKE: two pool fees, so allow for them in the minimum
        bytes memory path = abi.encodePacked(address(usdt), uint24(500), address(wbnb), uint24(500), address(cake));
        minOut = guard.minimumOut(address(usdt), address(cake), 1_000e6);
        d = abi.encodeCall(
            MockV3Router.exactInput, (MockV3Router.ExactInputParams(path, address(vault), _now() + 60, 1_000e6, minOut))
        );
        _exec(pid, OP_PK, _approveSwap(address(usdt), address(v3), 1_000e6, 0, d));

        // exact output: buy exactly 10 WBNB with CAKE (path reversed: out first)
        uint256 maxIn = guard.maximumIn(address(cake), address(wbnb), 10e18);
        path = abi.encodePacked(address(wbnb), uint24(500), address(cake));
        d = abi.encodeCall(
            MockV3Router.exactOutput, (MockV3Router.ExactOutputParams(path, address(vault), _now() + 60, 10e18, maxIn))
        );
        uint256 w0 = wbnb.balanceOf(address(vault));
        _exec(pid, OP_PK, _approveSwap(address(cake), address(v3), maxIn, 0, d));
        assertEq(wbnb.balanceOf(address(vault)) - w0, 10e18);
    }

    function test_twoSwapsInOneBatch() public {
        // USDT -> WBNB, then WBNB -> CAKE in the same signed batch
        uint256 out1 = guard.minimumOut(address(usdt), address(wbnb), 600e6);
        uint256 out2 = guard.minimumOut(address(wbnb), address(cake), out1);
        EPKVault.Call[] memory c = new EPKVault.Call[](6);
        c[0] = EPKVault.Call(address(usdt), 0, abi.encodeCall(IERC20.approve, (address(v2), 600e6)));
        c[1] = EPKVault.Call(
            address(v2),
            0,
            abi.encodeCall(
                MockV2Router.swapExactTokensForTokens,
                (600e6, out1, _path(address(usdt), address(wbnb)), address(vault), _now() + 60)
            )
        );
        c[2] = EPKVault.Call(address(wbnb), 0, abi.encodeCall(IERC20.approve, (address(v2), out1)));
        c[3] = EPKVault.Call(
            address(v2),
            0,
            abi.encodeCall(
                MockV2Router.swapExactTokensForTokens,
                (out1, out2, _path(address(wbnb), address(cake)), address(vault), _now() + 60)
            )
        );
        c[4] = EPKVault.Call(address(usdt), 0, abi.encodeCall(IERC20.approve, (address(v2), 0)));
        c[5] = EPKVault.Call(address(wbnb), 0, abi.encodeCall(IERC20.approve, (address(v2), 0)));
        uint256 k0 = cake.balanceOf(address(vault));
        _exec(pid, OP_PK, c);
        assertGe(cake.balanceOf(address(vault)) - k0, out2);
    }

    function test_plainPaymentsStillWork() public {
        _exec(pid, OP_PK, _one(address(usdt), 0, abi.encodeCall(IERC20.transfer, (friend, 100e6))));
        assertEq(usdt.balanceOf(friend), 100e6);
    }

    // ================================================================== attacks: where the money goes

    /// A1. The classic drain: swap the vault's tokens and send the output to the attacker.
    function test_attack_swapOutputToAttacker() public {
        uint256 minOut = guard.minimumOut(address(usdt), address(wbnb), 6_000e6);
        _execFails(
            pid,
            OP_PK,
            _v2ExactIn(address(usdt), address(wbnb), 6_000e6, minOut, attacker),
            abi.encodeWithSelector(DexGuard.RecipientNotVault.selector, attacker)
        );
        bytes memory d = abi.encodeCall(
            MockV3Router.exactInputSingle,
            (MockV3Router.ExactInputSingleParams(
                    address(usdt), address(cake), 500, attacker, _now() + 60, 1_000e6, 1, 0
                ))
        );
        _execFails(
            pid,
            OP_PK,
            _approveSwap(address(usdt), address(v3), 1_000e6, 0, d),
            abi.encodeWithSelector(DexGuard.RecipientNotVault.selector, attacker)
        );
        assertEq(wbnb.balanceOf(attacker) + cake.balanceOf(attacker), 0);
    }

    /// A2. Sell into a manipulated pool / sandwich: accept any price (minimum out = 1).
    function test_attack_noSlippageProtection() public {
        uint256 required = guard.minimumOut(address(usdt), address(wbnb), 6_000e6);
        _execFails(
            pid,
            OP_PK,
            _v2ExactIn(address(usdt), address(wbnb), 6_000e6, 1, address(vault)),
            abi.encodeWithSelector(DexGuard.PriceTooLow.selector, 1, required)
        );
    }

    /// A3. Overpay on an exact-output swap (spend far more than the fair price).
    function test_attack_overpayExactOutput() public {
        uint256 allowed = guard.maximumIn(address(usdt), address(wbnb), 1e18);
        bytes memory d = abi.encodeCall(
            MockV2Router.swapTokensForExactTokens,
            (1e18, 6_000e6, _path(address(usdt), address(wbnb)), address(vault), _now() + 60)
        );
        _execFails(
            pid,
            OP_PK,
            _approveSwap(address(usdt), address(v2), 6_000e6, 0, d),
            abi.encodeWithSelector(DexGuard.PriceTooHigh.selector, 6_000e6, allowed)
        );
    }

    /// A4. Route through a worthless / attacker-made token.
    function test_attack_junkTokenInPath() public {
        bytes memory d = abi.encodeCall(
            MockV2Router.swapExactTokensForTokens,
            (1_000e6, 1, _path3(address(usdt), address(junk), address(wbnb)), address(vault), _now() + 60)
        );
        _execFails(
            pid,
            OP_PK,
            _approveSwap(address(usdt), address(v2), 1_000e6, 0, d),
            abi.encodeWithSelector(DexGuard.TokenNotAllowed.selector, address(junk))
        );
    }

    /// A5. Hide a swap inside the router's multicall.
    function test_attack_multicallBypass() public {
        bytes[] memory inner = new bytes[](1);
        inner[0] = abi.encodeCall(
            MockV2Router.swapExactTokensForTokens,
            (1_000e6, 1, _path(address(usdt), address(wbnb)), attacker, _now() + 60)
        );
        bytes memory d = abi.encodeCall(MockV2Router.multicall, (inner));
        _execFails(
            pid,
            OP_PK,
            _approveSwap(address(usdt), address(v2), 1_000e6, 0, d),
            abi.encodeWithSelector(DexGuard.UnsupportedCall.selector, address(v2), MockV2Router.multicall.selector)
        );
    }

    /// A6. An unsupported router function (fee-on-transfer variant).
    function test_attack_unsupportedRouterFunction() public {
        bytes memory d = abi.encodeCall(
            MockV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens,
            (1_000e6, 1, _path(address(usdt), address(wbnb)), address(vault), _now() + 60)
        );
        bytes4 sel = MockV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens.selector;
        _execFails(
            pid,
            OP_PK,
            _approveSwap(address(usdt), address(v2), 1_000e6, 0, d),
            abi.encodeWithSelector(DexGuard.UnsupportedCall.selector, address(v2), sel)
        );
    }

    /// A7. Approve a non-router (even an allowlisted business partner) to pull tokens.
    function test_attack_approveNonRouter() public {
        _execFails(
            pid,
            OP_PK,
            _one(address(usdt), 0, abi.encodeCall(IERC20.approve, (friend, 1_000e6))),
            abi.encodeWithSelector(DexGuard.ApproveToNonRouter.selector, friend)
        );
    }

    /// A8. Sign a swap now, hold it back, run it later at a worse price.
    function test_attack_farDeadline() public {
        uint256 minOut = guard.minimumOut(address(usdt), address(wbnb), 600e6);
        uint256 dl = _now() + 2 days;
        bytes memory d = abi.encodeCall(
            MockV2Router.swapExactTokensForTokens, (600e6, minOut, _path(address(usdt), address(wbnb)), address(vault), dl)
        );
        _execFails(
            pid,
            OP_PK,
            _approveSwap(address(usdt), address(v2), 600e6, 0, d),
            abi.encodeWithSelector(DexGuard.BadDeadline.selector, dl)
        );
    }

    /// A9. Too big a single trade for this setup.
    function test_attack_tooLargeTrade() public {
        bytes memory d = abi.encodeCall(
            MockV2Router.swapExactTokensForTokens,
            (60_000e6, 1, _path(address(usdt), address(wbnb)), address(vault), _now() + 60)
        );
        _execFails(
            pid,
            OP_PK,
            _approveSwap(address(usdt), address(v2), 60_000e6, 0, d),
            abi.encodeWithSelector(DexGuard.AmountTooLarge.selector, address(usdt), 60_000e6, 50_000e6)
        );
    }

    // ================================================================== attacks: prices

    /// A10. Stale or broken oracle: no reliable price, no swap.
    function test_attack_staleOrBrokenPrice() public {
        vm.warp(_now() + 2 hours); // WBNB feed allows 1 hour
        usdtFeed.set(1e8);
        EPKVault.Call[] memory c = _v2ExactIn(address(usdt), address(wbnb), 600e6, 0.98e18, address(vault));
        _execFails(pid, OP_PK, c, abi.encodeWithSelector(DexGuard.StalePrice.selector, address(wbnb)));

        wbnbFeed.set(-1);
        c = _v2ExactIn(address(usdt), address(wbnb), 600e6, 0.98e18, address(vault));
        _execFails(pid, OP_PK, c, abi.encodeWithSelector(DexGuard.BadPrice.selector, address(wbnb)));

        wbnbFeed.set(200_000e8); // above the configured sanity bound
        c = _v2ExactIn(address(usdt), address(wbnb), 600e6, 0.98e18, address(vault));
        _execFails(pid, OP_PK, c, abi.encodeWithSelector(DexGuard.BadPrice.selector, address(wbnb)));
    }

    // ================================================================== attacks: the real result

    /// A11. The router (or a token that turned on a transfer tax) delivers less than it promised:
    ///      every pre-check passes, the after-batch balance check rejects the whole batch.
    function test_attack_routerDeliversLess() public {
        v2.setShortBps(100); // 1 % short
        uint256 minOut = guard.minimumOut(address(usdt), address(wbnb), 6_000e6);
        _execFailsWith(
            pid,
            OP_PK,
            _v2ExactIn(address(usdt), address(wbnb), 6_000e6, minOut, address(vault)),
            DexGuard.BalanceCheckFailed.selector
        );
    }

    /// A12. The vault's own limits still bound everything the guard allows.
    function test_vaultLimitsStillApply() public {
        // 3 swaps of 40,000 USDT would exceed the vault's 100,000 USDT/day
        usdt.mint(address(vault), 100_000e6);
        for (uint256 i = 0; i < 2; i++) {
            uint256 minOut = guard.minimumOut(address(usdt), address(wbnb), 40_000e6);
            _exec(pid, OP_PK, _v2ExactIn(address(usdt), address(wbnb), 40_000e6, minOut, address(vault)));
        }
        uint256 m = guard.minimumOut(address(usdt), address(wbnb), 40_000e6);
        _execFails(
            pid,
            OP_PK,
            _v2ExactIn(address(usdt), address(wbnb), 40_000e6, m, address(vault)),
            abi.encodeWithSelector(EPKVault.LimitExceeded.selector, address(usdt), 40_000e6, 20_000e6)
        );
    }

    // ================================================================== agent sessions (vault 2.1.0)

    function test_session_guardedSwapWorksAndAttacksFail() public {
        uint256 sid = _openSession(ENV);
        uint256 minOut = guard.minimumOut(address(usdt), address(wbnb), 600e6);
        _exec(sid, AGENT_PK, _v2ExactIn(address(usdt), address(wbnb), 600e6, minOut, address(vault)));

        _execFails(
            sid,
            AGENT_PK,
            _v2ExactIn(address(usdt), address(wbnb), 600e6, minOut, attacker),
            abi.encodeWithSelector(DexGuard.RecipientNotVault.selector, attacker)
        );
        _execFails(
            sid,
            AGENT_PK,
            _v2ExactIn(address(usdt), address(wbnb), 600e6, 1, address(vault)),
            abi.encodeWithSelector(DexGuard.PriceTooLow.selector, 1, minOut)
        );
    }

    function test_session_budgetStillApplies() public {
        uint256 sid = _openSession(ENV);
        uint256 minOut = guard.minimumOut(address(usdt), address(wbnb), 12_000e6);
        _execFails(
            sid,
            AGENT_PK,
            _v2ExactIn(address(usdt), address(wbnb), 12_000e6, minOut, address(vault)),
            abi.encodeWithSelector(EPKVault.BudgetExceeded.selector, address(usdt), 12_000e6, 10_000e6)
        );
    }

    /// The other execution path is closed: an unguarded session cannot call a router at all,
    /// even if the envelope allows the call. It can still make plain payments.
    function test_session_withoutGuardCannotSwap() public {
        uint256 sid = _openSession(ENV_NOGUARD);
        uint256 minOut = guard.minimumOut(address(usdt), address(wbnb), 600e6);
        _execFails(
            sid,
            AGENT_PK,
            _v2ExactIn(address(usdt), address(wbnb), 600e6, minOut, address(vault)),
            abi.encodeWithSelector(EPKVault.GuardRequired.selector)
        );
        bytes[] memory inner = new bytes[](0);
        _execFails(
            sid,
            AGENT_PK,
            _one(address(v2), 0, abi.encodeCall(MockV2Router.multicall, (inner))),
            abi.encodeWithSelector(EPKVault.GuardRequired.selector)
        );
        _exec(sid, AGENT_PK, _one(friend, 0.1 ether, ""));
        assertEq(friend.balance, 0.1 ether);
    }

    /// Every change of a session guard waits in the timelock — adding one too: on an unguarded
    /// envelope a permissive guard would unlock router calls (a hidden loosening).
    function test_session_guardChangesAreTimelocked() public {
        vm.prank(guardian);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        vault.setEnvelopeGuard(ENV_NOGUARD, address(guard));
        vm.prank(admin);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        vault.setEnvelopeGuard(ENV_NOGUARD, address(guard));

        // scheduled, a guardian (or the Watchtower) can veto it ...
        bytes memory op = abi.encodeCall(EPKVault.setEnvelopeGuard, (ENV_NOGUARD, address(guard)));
        vm.prank(admin);
        bytes32 id = vault.schedule(op, bytes32("add guard"));
        vm.prank(guardian2);
        vault.cancel(id);

        // ... or, after the delay, it applies to the envelope's sessions
        vm.prank(admin);
        vault.schedule(op, bytes32("add guard again"));
        vm.warp(_now() + DELAY);
        usdtFeed.set(1e8);
        wbnbFeed.set(600e8);
        cakeFeed.set(2e18);
        vm.prank(admin);
        vault.executeScheduled(op, bytes32("add guard again"));
        assertEq(vault.envelopeGuard(ENV_NOGUARD), address(guard));
        uint256 sid = _openSession(ENV_NOGUARD);
        uint256 minOut = guard.minimumOut(address(usdt), address(wbnb), 600e6);
        _exec(sid, AGENT_PK, _v2ExactIn(address(usdt), address(wbnb), 600e6, minOut, address(vault)));

        // removing it is timelocked as well
        vm.prank(guardian);
        vm.expectRevert(EPKVault.NotTimelocked.selector);
        vault.setEnvelopeGuard(ENV_NOGUARD, address(0));
    }

    function test_version() public view {
        assertEq(vault.vaultVersion(), 20_300);
    }
}
