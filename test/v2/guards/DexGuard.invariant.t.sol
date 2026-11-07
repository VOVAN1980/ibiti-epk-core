// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {EPKVault} from "../../../contracts/v2/EPKVault.sol";
import {DexGuard} from "../../../contracts/v2/guards/DexGuard.sol";
import {DecToken, MockFeed, MockV2Router, MockV3Router} from "./GuardMocks.sol";
import {GuardBase} from "./GuardBase.sol";

/// The operator key is compromised: the handler signs whatever it wants — swaps to the attacker,
/// any minimum, manipulated pools, routers that deliver less — while prices move.
contract CompromisedTrader is Test {
    EPKVault vault;
    DexGuard guard;
    MockV2Router v2;
    MockV3Router v3;
    DecToken[3] tokens; // usdt, wbnb, cake
    MockFeed wbnbFeed;
    MockFeed usdtFeed;
    MockFeed cakeFeed;
    uint256 pid;
    uint256 pk;
    address attacker;

    uint256 public swapsTried;
    uint256 public swapsDone;
    uint256 public violations; // a successful swap that returned less than fair value minus slippage
    uint256 public worstKeepBps = type(uint256).max;

    constructor(
        EPKVault vault_,
        DexGuard guard_,
        MockV2Router v2_,
        MockV3Router v3_,
        DecToken[3] memory tokens_,
        MockFeed[3] memory feeds_,
        uint256 pid_,
        uint256 pk_,
        address attacker_
    ) {
        (vault, guard, v2, v3, tokens, pid, pk, attacker) = (vault_, guard_, v2_, v3_, tokens_, pid_, pk_, attacker_);
        (usdtFeed, wbnbFeed, cakeFeed) = (feeds_[0], feeds_[1], feeds_[2]);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    /// Price moves; pools either follow (honest) or are pushed away from the oracle (manipulated).
    function movePrice(uint256 bnbPrice, uint256 poolKeepBps) external {
        bnbPrice = bound(bnbPrice, 300e8, 1_200e8);
        poolKeepBps = bound(poolKeepBps, 5_000, 10_500);
        vm.warp(_now() + 10 minutes);
        wbnbFeed.set(int256(bnbPrice));
        usdtFeed.set(1e8);
        cakeFeed.set(2e18);
        uint256[3] memory usd = [uint256(1e18), bnbPrice * 1e10, 2e18];
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = 0; j < 3; j++) {
                if (i == j) continue;
                uint256 r = 10 ** tokens[j].decimals() * usd[i] / usd[j] * 1e18 / 10 ** tokens[i].decimals();
                v2.setRate(address(tokens[i]), address(tokens[j]), r * poolKeepBps / 10_000);
                v3.setRate(address(tokens[i]), address(tokens[j]), r * poolKeepBps / 10_000);
            }
        }
    }

    function setShort(uint256 bps) external {
        bps = bound(bps, 0, 300);
        v2.setShortBps(bps);
        v3.setShortBps(bps);
    }

    function swap(uint256 from, uint256 to, uint256 amountSeed, uint256 minBps, bool useV3, uint8 mode) external {
        from = bound(from, 0, 2);
        to = bound(to, 0, 2);
        if (from == to) to = (to + 1) % 3;
        DecToken tIn = tokens[from];
        DecToken tOut = tokens[to];
        uint256 bal = tIn.balanceOf(address(vault));
        if (bal < 10) return;
        uint256 amountIn = bound(amountSeed, 1, Math.min(bal, guard.tokenConfig(address(tIn)).maxAmountIn));
        uint256 required;
        try guard.minimumOut(address(tIn), address(tOut), amountIn) returns (uint256 m) {
            required = m;
        } catch {
            return;
        }
        // mode 0: honest bot (the guard's own minimum); 1: random minimum; 2: honest terms but output
        // to the attacker; 3: random minimum to the attacker
        mode = mode % 4;
        uint256 minOut = mode % 2 == 0 ? required : required * bound(minBps, 0, 11_000) / 9_900;
        address recipient = mode >= 2 ? attacker : address(vault);
        address router = useV3 ? address(v3) : address(v2);

        bytes memory d = useV3
            ? abi.encodeCall(
                MockV3Router.exactInputSingle,
                (MockV3Router.ExactInputSingleParams(
                        address(tIn), address(tOut), 500, recipient, _now() + 60, amountIn, minOut, 0
                    ))
            )
            : abi.encodeCall(
                MockV2Router.swapExactTokensForTokens,
                (amountIn, minOut, _pair(address(tIn), address(tOut)), recipient, _now() + 60)
            );
        EPKVault.Call[] memory c = new EPKVault.Call[](3);
        c[0] = EPKVault.Call(address(tIn), 0, abi.encodeCall(IERC20.approve, (router, amountIn)));
        c[1] = EPKVault.Call(router, 0, d);
        c[2] = EPKVault.Call(address(tIn), 0, abi.encodeCall(IERC20.approve, (router, 0)));

        uint256 deadline = _now() + 1 hours;
        bytes32 digest = vault.getExecuteDigest(pid, vm.addr(pk), c, vault.nonces(pid), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        uint256 inUsd = Math.mulDiv(amountIn, guard.price(address(tIn)), 10 ** tIn.decimals());
        uint256 outBefore = tOut.balanceOf(address(vault));

        swapsTried++;
        vm.prank(vm.addr(pk));
        try vault.execute(pid, c, deadline, abi.encodePacked(r, s, v), "") {
            swapsDone++;
            uint256 received = tOut.balanceOf(address(vault)) - outBefore;
            uint256 outUsd = Math.mulDiv(received, guard.price(address(tOut)), 10 ** tOut.decimals());
            uint256 keep = inUsd == 0 ? 10_000 : outUsd * 10_000 / inUsd;
            if (keep < worstKeepBps) worstKeepBps = keep;
            // fair value minus 1 % slippage, with one unit of rounding on tiny trades
            if (outUsd * 10_000 + 2 * 10 ** 18 < inUsd * 9_900) violations++;
        } catch {}
    }

    function _pair(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }
}

contract DexGuardInvariantTest is GuardBase {
    CompromisedTrader trader;

    function setUp() public {
        _deployMarket();
        _deployGuard();
        _deployVault();
        _setUpVault(address(guard));
        trader = new CompromisedTrader(
            vault, guard, v2, v3, [usdt, wbnb, cake], [usdtFeed, wbnbFeed, cakeFeed], pid, OP_PK, attacker
        );
        targetContract(address(trader));
    }

    /// Nothing ever reaches the attacker.
    function invariant_attackerGetsNothing() public view {
        assertEq(usdt.balanceOf(attacker) + wbnb.balanceOf(attacker) + cake.balanceOf(attacker), 0);
        assertEq(attacker.balance, 0);
    }

    /// Every swap that went through returned at least the fair value minus the allowed slippage.
    function invariant_everySwapAtFairPrice() public view {
        assertEq(trader.violations(), 0);
    }

    /// No allowance survives a batch.
    function invariant_noAllowanceLeft() public view {
        assertEq(usdt.allowance(address(vault), address(v2)) + usdt.allowance(address(vault), address(v3)), 0);
        assertEq(wbnb.allowance(address(vault), address(v2)) + wbnb.allowance(address(vault), address(v3)), 0);
        assertEq(cake.allowance(address(vault), address(v2)) + cake.allowance(address(vault), address(v3)), 0);
    }

    function afterInvariant() external view {
        console.log("swaps tried / done:", trader.swapsTried(), trader.swapsDone());
        console.log("worst kept value (bps of fair):", trader.worstKeepBps());
    }
}
