// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EPKVault} from "../../../contracts/v2/EPKVault.sol";
import {DexGuard} from "../../../contracts/v2/guards/DexGuard.sol";
import {ThreatFeedGuard} from "../../../contracts/v2/guards/ThreatFeedGuard.sol";
import {CompositeGuard} from "../../../contracts/v2/guards/CompositeGuard.sol";
import {RejectAllValidator} from "../V2Mocks.sol";
import {MockV2Router} from "./GuardMocks.sol";
import {GuardBase} from "./GuardBase.sol";

/// ThreatFeed V2 and CompositeGuard, on a real vault 2.1.0 whose trading policy runs DexGuard AND the feed.
contract ThreatFeedCompositeTest is GuardBase {
    ThreatFeedGuard feed;
    CompositeGuard composite;
    address feedOwner = makeAddr("feedOwner");
    address responder = makeAddr("responder");

    function setUp() public {
        _deployMarket();
        _deployGuard();
        feed = new ThreatFeedGuard(feedOwner, 1 days);
        vm.prank(feedOwner);
        feed.setBlocker(responder, true);
        address[] memory kids = new address[](2);
        kids[0] = address(guard);
        kids[1] = address(feed);
        composite = new CompositeGuard(kids, new bool[](2));
        _deployVault();
        _setUpVault(address(composite));
    }

    function _block(address who) internal {
        address[] memory a = new address[](1);
        a[0] = who;
        vm.prank(responder);
        feed.blockAddresses(a, "drainer");
    }

    function _list(address who) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = who;
    }

    // ------------------------------------------------------------------ feed on the vault

    function test_compositeAllowsCleanTrades() public {
        uint256 minOut = guard.minimumOut(address(usdt), address(wbnb), 600e6);
        _exec(pid, OP_PK, _v2ExactIn(address(usdt), address(wbnb), 600e6, minOut, address(vault)));
    }

    /// A token that turned out to be exploited is blocked in seconds; every swap path through it stops.
    function test_blockedTokenStopsSwaps() public {
        _block(address(cake));
        uint256 minOut = guard.minimumOut(address(usdt), address(wbnb), 600e6); // the DEX rules pass ...
        bytes memory d = abi.encodeCall(
            MockV2Router.swapExactTokensForTokens,
            (600e6, minOut, _path3(address(usdt), address(cake), address(wbnb)), address(vault), _now() + 60)
        );
        _execFails(
            pid,
            OP_PK,
            _approveSwap(address(usdt), address(v2), 600e6, 0, d),
            abi.encodeWithSelector(ThreatFeedGuard.BlockedAddress.selector, address(cake))
        );
    }

    /// A payee that turned out to be a drainer: payments to it stop at once.
    function test_blockedRecipientStopsPayments() public {
        _block(friend);
        _execFails(
            pid,
            OP_PK,
            _one(address(usdt), 0, abi.encodeCall(IERC20.transfer, (friend, 1e6))),
            abi.encodeWithSelector(ThreatFeedGuard.BlockedAddress.selector, friend)
        );
    }

    /// The after-batch check works through the composite too.
    function test_compositeRunsAfterBatch() public {
        v2.setShortBps(100);
        uint256 minOut = guard.minimumOut(address(usdt), address(wbnb), 600e6);
        _execFailsWith(
            pid,
            OP_PK,
            _v2ExactIn(address(usdt), address(wbnb), 600e6, minOut, address(vault)),
            DexGuard.BalanceCheckFailed.selector
        );
    }

    // ------------------------------------------------------------------ feed management

    function test_unblockWaitsAndCanBeVetoed() public {
        _block(friend);
        address[] memory a = _list(friend);

        vm.prank(responder);
        vm.expectRevert(ThreatFeedGuard.NotOwner.selector);
        feed.scheduleUnblock(a); // responders can only block

        vm.prank(feedOwner);
        feed.scheduleUnblock(a);
        vm.expectRevert(abi.encodeWithSelector(ThreatFeedGuard.NotReady.selector, friend, _now() + 1 days));
        feed.executeUnblock(a);

        // a responder vetoes a suspicious unblock (e.g. the owner key was stolen)
        vm.prank(responder);
        feed.cancelUnblock(a);
        vm.warp(_now() + 2 days);
        vm.expectRevert(abi.encodeWithSelector(ThreatFeedGuard.NotScheduled.selector, friend));
        feed.executeUnblock(a);
        assertTrue(feed.blocked(friend));

        // a legitimate unblock goes through after the delay
        vm.prank(feedOwner);
        feed.scheduleUnblock(a);
        vm.warp(_now() + 1 days);
        feed.executeUnblock(a);
        assertFalse(feed.blocked(friend));
    }

    function test_reblockCancelsPendingUnblock() public {
        _block(friend);
        vm.prank(feedOwner);
        feed.scheduleUnblock(_list(friend));
        _block(friend);
        assertEq(feed.unblockReadyAt(friend), 0);
    }

    function test_feedRoles() public {
        vm.prank(attacker);
        vm.expectRevert(ThreatFeedGuard.NotOwnerOrBlocker.selector);
        feed.blockAddresses(_list(friend), "x");
        vm.prank(attacker);
        vm.expectRevert(ThreatFeedGuard.NotOwner.selector);
        feed.setBlocker(attacker, true);

        vm.prank(feedOwner);
        feed.transferOwnership(attacker);
        assertEq(feed.owner(), feedOwner); // two-step: nothing changes until accepted
        vm.prank(attacker);
        feed.acceptOwnership();
        assertEq(feed.owner(), attacker);

        vm.expectRevert(ThreatFeedGuard.BadDelay.selector);
        new ThreatFeedGuard(feedOwner, 10 minutes);
        vm.expectRevert(ThreatFeedGuard.ZeroAddress.selector);
        new ThreatFeedGuard(address(0), 1 days);
    }

    function test_isCallBlockedView() public {
        _block(attacker);
        bytes memory d = abi.encodeCall(IERC20.transfer, (attacker, 5));
        assertTrue(feed.isCallBlocked(address(usdt), d));
        assertFalse(feed.isCallBlocked(address(usdt), abi.encodeCall(IERC20.transfer, (friend, 5))));
        assertTrue(feed.isCallBlocked(attacker, ""));
    }

    /// An address hidden anywhere in the arguments — any word position — is found.
    function testFuzz_blockedAddressAnywhereInArgs(uint8 position, uint8 words, address bad) public {
        vm.assume(bad != address(0));
        words = uint8(bound(words, 1, 20));
        position = uint8(bound(position, 0, words - 1));
        _block(bad);
        bytes memory data = abi.encodePacked(bytes4(0x12345678));
        for (uint256 i = 0; i < words; i++) {
            data = abi.encodePacked(data, i == position ? bytes32(uint256(uint160(bad))) : bytes32(uint256(1) << 200));
        }
        vm.expectRevert(abi.encodeWithSelector(ThreatFeedGuard.BlockedAddress.selector, bad));
        feed.validate(0, address(0), address(0), address(usdt), 0, data);
    }

    // ------------------------------------------------------------------ composite rules

    function test_compositeConstructorRules() public {
        address[] memory none = new address[](0);
        vm.expectRevert(CompositeGuard.BadChildren.selector);
        new CompositeGuard(none, new bool[](0));
        address[] memory two = new address[](2);
        two[0] = address(guard);
        two[1] = address(guard);
        vm.expectRevert(CompositeGuard.BadChildren.selector);
        new CompositeGuard(two, new bool[](2)); // duplicate
        two[1] = makeAddr("eoa");
        vm.expectRevert(CompositeGuard.BadChildren.selector);
        new CompositeGuard(two, new bool[](2)); // no code
        two[1] = address(feed);
        vm.expectRevert(CompositeGuard.BadChildren.selector);
        new CompositeGuard(two, new bool[](1)); // length mismatch
        address[] memory nine = new address[](9);
        vm.expectRevert(CompositeGuard.BadChildren.selector);
        new CompositeGuard(nine, new bool[](9));

        (address[] memory kids, bool[] memory legacy) = composite.children();
        assertEq(kids.length, 2);
        assertFalse(legacy[0]);
    }

    /// Only the vault itself may act for the vault: no nesting, no writing into its slot.
    function test_compositeOnlyVaultSpeaksForVault() public {
        vm.prank(attacker);
        vm.expectRevert(CompositeGuard.NotVault.selector);
        composite.validateFor(address(vault), 1, address(0), address(0), address(usdt), 0, "");
        vm.prank(attacker);
        vm.expectRevert(CompositeGuard.NotVault.selector);
        composite.afterBatchFor(address(vault), 1);
    }

    /// Legacy validators (validate only) can be combined with EPK guards.
    function test_legacyChild() public {
        address[] memory kids = new address[](2);
        kids[0] = address(feed);
        kids[1] = address(new RejectAllValidator());
        bool[] memory legacy = new bool[](2);
        legacy[1] = true;
        CompositeGuard c = new CompositeGuard(kids, legacy);
        vm.expectRevert(RejectAllValidator.Rejected.selector);
        c.validate(0, address(0), address(0), address(usdt), 0, "");
        c.afterBatch(0); // legacy children are skipped after the batch
    }
}
