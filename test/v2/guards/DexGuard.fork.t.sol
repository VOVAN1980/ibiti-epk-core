// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EPKVault} from "../../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../../contracts/v2/EPKVaultFactory.sol";
import {EPKRegistry} from "../../../contracts/v2/EPKRegistry.sol";
import {DexGuard, IChainlinkFeed} from "../../../contracts/v2/guards/DexGuard.sol";
import {DecToken, MockFeed} from "./GuardMocks.sol";

interface IPancakeV2Router {
    function WETH() external view returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256, uint256, uint256);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory);
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
}

/// DexGuard against the REAL PancakeSwap V2 router and REAL Chainlink feeds on a local fork of BSC
/// Testnet. Run with:  BSC_TESTNET_FORK_RPC=https://bsc-testnet-rpc.publicnode.com forge test --match-path "test/v2/guards/DexGuard.fork.t.sol" -vv
/// (skipped when the variable is not set, e.g. in CI).
contract DexGuardForkTest is Test {
    IPancakeV2Router constant ROUTER = IPancakeV2Router(0xD99D1c33F9fC3444f8101754aBC46c52416550D1);
    address constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    address constant BUSD = 0x78867BbEeF44f2326bF8DDd1941a4439382EF2A7;
    address constant BNB_USD = 0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526; // Chainlink, BSC Testnet
    address constant BUSD_USD = 0x9331b55D9830EF609A2aBCfAc0FBCE050A52fdEa; // Chainlink, BSC Testnet
    uint256 constant OP_PK = 0x0F;
    uint256 constant SLIPPAGE_BPS = 100;

    EPKVault vault;
    DexGuard guard;
    DecToken fusd; // our own token, with a pool we seed at the Chainlink price
    uint256 guarded; // trading policy with DexGuard
    uint256 unguarded; // the same calls without a guard: what a plain bot wallet would do
    address attacker = makeAddr("attacker");
    bool forked;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_TESTNET_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        assertEq(block.chainid, 97);
        assertEq(ROUTER.WETH(), WBNB);

        // a fair pool for fUSD at today's Chainlink BNB price
        fusd = new DecToken("fUSD", 18);
        (, int256 bnbUsd,,,) = IChainlinkFeed(BNB_USD).latestRoundData();
        uint256 fusdPerBnb = uint256(bnbUsd) * 1e10; // 8 -> 18 decimals
        fusd.mint(address(this), fusdPerBnb * 1_000);
        fusd.approve(address(ROUTER), type(uint256).max);
        vm.deal(address(this), 1_000 ether);
        ROUTER.addLiquidityETH{value: 1_000 ether}(address(fusd), fusdPerBnb * 1_000, 0, 0, address(this), block.timestamp);
        MockFeed fusdFeed = new MockFeed(8, 1e8);

        DexGuard.RouterInit[] memory r = new DexGuard.RouterInit[](1);
        r[0] = DexGuard.RouterInit(address(ROUTER), DexGuard.RouterKind.V2);
        DexGuard.TokenInit[] memory t = new DexGuard.TokenInit[](3);
        t[0] = DexGuard.TokenInit(WBNB, BNB_USD, 1 days, 100e18, 1e8, 1e13);
        t[1] = DexGuard.TokenInit(BUSD, BUSD_USD, 2 days, 100_000e18, 0.5e8, 2e8);
        t[2] = DexGuard.TokenInit(address(fusd), address(fusdFeed), 1 days, 1_000_000e18, 0.5e8, 2e8);
        guard = new DexGuard(WBNB, SLIPPAGE_BPS, 10 minutes, r, t);

        EPKVault impl = new EPKVault();
        EPKRegistry registry = new EPKRegistry(makeAddr("registryOwner"), address(impl));
        EPKVaultFactory factory = new EPKVaultFactory(address(impl), address(registry));
        address[] memory g = new address[](2);
        g[0] = makeAddr("guardian");
        g[1] = makeAddr("guardian2");
        address admin = makeAddr("admin");
        vm.prank(admin);
        vault = EPKVault(payable(factory.createVault(g, 1 days, address(0), bytes32("fork"))));

        vm.startPrank(admin);
        vault.setAsset(address(0), 100 ether, 1 days, type(uint128).max);
        vault.setAsset(BUSD, 1_000_000e18, 1 days, type(uint128).max);
        vault.setAsset(address(fusd), 1_000_000e18, 1 days, type(uint128).max);
        vault.addDestination(address(ROUTER));
        guarded = vault.createPolicy(vm.addr(OP_PK), 0, 10 ether, address(guard));
        unguarded = vault.createPolicy(vm.addr(OP_PK), 0, 10 ether, address(0));
        uint256[2] memory pids = [guarded, unguarded];
        for (uint256 i = 0; i < 2; i++) {
            vault.setAgent(pids[i], vm.addr(OP_PK), true, 0);
            vault.setCall(pids[i], address(ROUTER), IPancakeV2Router.swapExactETHForTokens.selector, true);
            vault.setCall(pids[i], address(ROUTER), IPancakeV2Router.swapExactTokensForETH.selector, true);
            vault.setCall(
                pids[i], address(ROUTER), IPancakeV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens.selector, true
            );
            vault.setCall(pids[i], address(fusd), IERC20.approve.selector, true);
        }
        vault.finalizeSetup();
        vm.stopPrank();
        vm.deal(address(vault), 10 ether);
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _bnbIn(uint256 policyId, address tokenOut, uint256 amount, uint256 minOut, address to) internal returns (bool ok, bytes memory err) {
        EPKVault.Call[] memory c = new EPKVault.Call[](1);
        c[0] = EPKVault.Call(
            address(ROUTER),
            amount,
            abi.encodeCall(IPancakeV2Router.swapExactETHForTokens, (minOut, _path(WBNB, tokenOut), to, block.timestamp + 300))
        );
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 d = vault.getExecuteDigest(policyId, vm.addr(OP_PK), c, vault.nonces(policyId), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OP_PK, d);
        vm.prank(vm.addr(OP_PK));
        try vault.execute(policyId, c, deadline, abi.encodePacked(r, s, v), "") {
            ok = true;
        } catch (bytes memory e) {
            err = e;
        }
    }

    /// The real WBNB/BUSD pool on BSC Testnet is far from the Chainlink price. A bot that trusts the
    /// pool's own quote would sell BNB at that price; the guarded vault refuses.
    function test_fork_mispricedRealPoolIsRefused() public onlyFork {
        uint256 amount = 0.1 ether;
        uint256 poolOut = ROUTER.getAmountsOut(amount, _path(WBNB, BUSD))[1];
        uint256 fairOut = guard.minimumOut(WBNB, BUSD, amount) * 10_000 / (10_000 - SLIPPAGE_BPS);
        uint256 keepBps = poolOut * 10_000 / fairOut;
        console.log("BSC Testnet fork block    :", block.number);
        console.log("Chainlink BNB/USD (8 dec) :", uint256(guard.price(WBNB) / 1e10));
        console.log("pool pays BUSD for 0.1 BNB:", poolOut);
        console.log("fair BUSD for 0.1 BNB     :", fairOut);
        console.log("pool keeps (bps of fair)   :", keepBps);

        (bool ok, bytes memory err) = _bnbIn(guarded, BUSD, amount, poolOut, address(vault));
        if (keepBps < 10_000 - SLIPPAGE_BPS) {
            assertFalse(ok, "guard must refuse a mispriced pool");
            assertEq(bytes4(err), DexGuard.PriceTooLow.selector);
            // the same trade without the guard goes through and loses the difference
            uint256 before = IERC20(BUSD).balanceOf(address(vault));
            (bool ok2,) = _bnbIn(unguarded, BUSD, amount, poolOut, address(vault));
            assertTrue(ok2);
            uint256 got = IERC20(BUSD).balanceOf(address(vault)) - before;
            console.log("unguarded wallet received :", got);
            console.log("unguarded loss vs fair (bps):", 10_000 - got * 10_000 / fairOut);
        } else {
            assertTrue(ok, "a fairly priced pool must be usable");
        }
    }

    /// A pool at the Chainlink price works through the real router, both directions.
    function test_fork_fairPoolSwapsWork() public onlyFork {
        uint256 amount = 0.5 ether;
        uint256 quote = ROUTER.getAmountsOut(amount, _path(WBNB, address(fusd)))[1];
        uint256 before = fusd.balanceOf(address(vault));
        (bool ok, bytes memory err) = _bnbIn(guarded, address(fusd), amount, quote, address(vault));
        assertTrue(ok, string(err));
        uint256 got = fusd.balanceOf(address(vault)) - before;
        assertGe(got, quote);
        console.log("BNB -> fUSD through PancakeSwap, received:", got);

        // and back: fUSD -> BNB (approve, swap, reset the allowance)
        uint256 minBnb = ROUTER.getAmountsOut(got, _path(address(fusd), WBNB))[1];
        EPKVault.Call[] memory c = new EPKVault.Call[](3);
        c[0] = EPKVault.Call(address(fusd), 0, abi.encodeCall(IERC20.approve, (address(ROUTER), got)));
        c[1] = EPKVault.Call(
            address(ROUTER),
            0,
            abi.encodeCall(
                IPancakeV2Router.swapExactTokensForETH, (got, minBnb, _path(address(fusd), WBNB), address(vault), block.timestamp + 300)
            )
        );
        c[2] = EPKVault.Call(address(fusd), 0, abi.encodeCall(IERC20.approve, (address(ROUTER), 0)));
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 d = vault.getExecuteDigest(guarded, vm.addr(OP_PK), c, vault.nonces(guarded), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OP_PK, d);
        uint256 bnbBefore = address(vault).balance;
        vm.prank(vm.addr(OP_PK));
        vault.execute(guarded, c, deadline, abi.encodePacked(r, s, v), "");
        assertGe(address(vault).balance - bnbBefore, minBnb);
    }

    /// Attacks signed by a compromised operator, against the real router.
    function test_fork_attacksOnRealRouterAreRefused() public onlyFork {
        uint256 quote = ROUTER.getAmountsOut(0.5 ether, _path(WBNB, address(fusd)))[1];

        (bool ok, bytes memory err) = _bnbIn(guarded, address(fusd), 0.5 ether, quote, attacker);
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(DexGuard.RecipientNotVault.selector, attacker));

        (ok, err) = _bnbIn(guarded, address(fusd), 0.5 ether, 1, address(vault));
        assertFalse(ok);
        assertEq(bytes4(err), DexGuard.PriceTooLow.selector);

        EPKVault.Call[] memory c = new EPKVault.Call[](1);
        c[0] = EPKVault.Call(
            address(ROUTER),
            0.5 ether,
            abi.encodeCall(
                IPancakeV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens,
                (1, _path(WBNB, address(fusd)), attacker, block.timestamp + 300)
            )
        );
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 d = vault.getExecuteDigest(guarded, vm.addr(OP_PK), c, vault.nonces(guarded), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OP_PK, d);
        vm.expectRevert(
            abi.encodeWithSelector(
                DexGuard.UnsupportedCall.selector,
                address(ROUTER),
                IPancakeV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens.selector
            )
        );
        vm.prank(vm.addr(OP_PK));
        vault.execute(guarded, c, deadline, abi.encodePacked(r, s, v), "");

        assertEq(fusd.balanceOf(attacker), 0);
        assertEq(attacker.balance, 0);
    }
}
