// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EPKVault} from "../../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../../contracts/v2/EPKVaultFactory.sol";
import {EPKRegistry} from "../../../contracts/v2/EPKRegistry.sol";
import {DexGuard} from "../../../contracts/v2/guards/DexGuard.sol";
import {DecToken, MockFeed, MockV2Router, MockV3Router} from "./GuardMocks.sol";

/// A real EPKVault 2.1.0 (proxy from the factory) trading through mock V2 / V3 routers, guarded by DexGuard.
/// Prices: USDT $1 (6 decimals), WBNB $600, CAKE $2 (its feed uses 18 decimals). Pools quote the fair
/// price minus a 0.3 % fee; the guard allows 1 % slippage.
abstract contract GuardBase is Test {
    uint256 constant DELAY = 1 days;
    uint256 constant SLIPPAGE_BPS = 100;
    uint256 constant MAX_DEADLINE = 10 minutes;
    uint256 constant ENV = 1; // guarded envelope
    uint256 constant ENV_NOGUARD = 2; // same calls, no guard
    uint256 constant OP_PK = 0x0F;
    uint256 constant AGENT_PK = 0xA1;

    EPKVaultFactory factory;
    EPKVault vault;
    DexGuard guard;
    MockV2Router v2;
    MockV3Router v3;
    DecToken usdt;
    DecToken wbnb;
    DecToken cake;
    DecToken junk;
    MockFeed usdtFeed;
    MockFeed wbnbFeed;
    MockFeed cakeFeed;
    uint256 pid; // ordinary policy guarded by DexGuard

    address admin = makeAddr("admin");
    address guardian = makeAddr("guardian");
    address guardian2 = makeAddr("guardian2");
    address manager = makeAddr("sessionManager");
    address friend = makeAddr("friend");
    address attacker = makeAddr("attacker");

    function _deployMarket() internal {
        usdt = new DecToken("USDT", 6);
        wbnb = new DecToken("WBNB", 18);
        cake = new DecToken("CAKE", 18);
        junk = new DecToken("JUNK", 18);
        usdtFeed = new MockFeed(8, 1e8);
        wbnbFeed = new MockFeed(8, 600e8);
        cakeFeed = new MockFeed(18, 2e18);
        v2 = new MockV2Router(address(wbnb));
        v3 = new MockV3Router(address(wbnb));
        vm.deal(address(v2), 1_000 ether); // native liquidity for swaps that pay out BNB
        _setFairRates(9_970); // 0.3 % pool fee
    }

    /// Pool rate = fair price * keepBps / 10_000 for every pair, on both routers.
    function _setFairRates(uint256 keepBps) internal {
        DecToken[4] memory t = [usdt, wbnb, cake, junk];
        for (uint256 i = 0; i < 4; i++) {
            for (uint256 j = 0; j < 4; j++) {
                if (i == j) continue;
                uint256 r = _fairRate(address(t[i]), address(t[j])) * keepBps / 10_000;
                v2.setRate(address(t[i]), address(t[j]), r);
                v3.setRate(address(t[i]), address(t[j]), r);
            }
        }
    }

    function _usd(address token) internal view returns (uint256) {
        if (token == address(usdt)) return 1e18;
        if (token == address(wbnb)) return 600e18;
        if (token == address(cake)) return 2e18;
        return 1e18; // junk: no feed in the guard, $1 in the pools
    }

    /// out per 1e18 units in: 10^decOut * pIn / pOut * 1e18 / 10^decIn
    function _fairRate(address a, address b) internal view returns (uint256) {
        return 10 ** DecToken(b).decimals() * _usd(a) / _usd(b) * 1e18 / 10 ** DecToken(a).decimals();
    }

    function _deployGuard() internal {
        DexGuard.RouterInit[] memory r = new DexGuard.RouterInit[](2);
        r[0] = DexGuard.RouterInit(address(v2), DexGuard.RouterKind.V2);
        r[1] = DexGuard.RouterInit(address(v3), DexGuard.RouterKind.V3);
        DexGuard.TokenInit[] memory t = new DexGuard.TokenInit[](3);
        t[0] = DexGuard.TokenInit(address(usdt), address(usdtFeed), 1 days, 50_000e6, 0.5e8, 2e8);
        t[1] = DexGuard.TokenInit(address(wbnb), address(wbnbFeed), 1 hours, 100e18, 1e8, 100_000e8);
        t[2] = DexGuard.TokenInit(address(cake), address(cakeFeed), 1 hours, 100_000e18, 0.01e18, 1_000e18);
        guard = new DexGuard(address(wbnb), SLIPPAGE_BPS, MAX_DEADLINE, r, t);
    }

    function _deployVault() internal {
        EPKVault impl = new EPKVault();
        EPKRegistry registry = new EPKRegistry(makeAddr("registryOwner"), address(impl));
        factory = new EPKVaultFactory(address(impl), address(registry));
        address[] memory g = new address[](2);
        g[0] = guardian;
        g[1] = guardian2;
        vm.prank(admin);
        vault = EPKVault(payable(factory.createVault(g, DELAY, address(0), bytes32("guards"))));
    }

    /// Calls a trading policy / envelope may use (the guard decides what is acceptable inside them).
    function _tradingCalls() internal view returns (address[] memory targets, bytes4[] memory sels) {
        targets = new address[](17);
        sels = new bytes4[](17);
        address[4] memory tok = [address(usdt), address(wbnb), address(cake), address(junk)];
        for (uint256 i = 0; i < 4; i++) {
            targets[i] = tok[i];
            sels[i] = IERC20.approve.selector;
        }
        bytes4[7] memory v2s = [
            MockV2Router.swapExactTokensForTokens.selector,
            MockV2Router.swapTokensForExactTokens.selector,
            MockV2Router.swapExactETHForTokens.selector,
            MockV2Router.swapETHForExactTokens.selector,
            MockV2Router.swapExactTokensForETH.selector,
            MockV2Router.swapTokensForExactETH.selector,
            MockV2Router.multicall.selector
        ];
        for (uint256 i = 0; i < 7; i++) {
            targets[4 + i] = address(v2);
            sels[4 + i] = v2s[i];
        }
        targets[11] = address(v2);
        sels[11] = MockV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens.selector;
        bytes4[4] memory v3s = [
            MockV3Router.exactInputSingle.selector,
            MockV3Router.exactInput.selector,
            MockV3Router.exactOutputSingle.selector,
            MockV3Router.exactOutput.selector
        ];
        for (uint256 i = 0; i < 4; i++) {
            targets[12 + i] = address(v3);
            sels[12 + i] = v3s[i];
        }
        targets[16] = address(usdt);
        sels[16] = IERC20.transfer.selector;
    }

    function _setUpVault(address policyGuard) internal {
        vm.startPrank(admin);
        vault.setAsset(address(usdt), 100_000e6, 1 days, type(uint128).max);
        vault.setAsset(address(wbnb), 1_000e18, 1 days, type(uint128).max);
        vault.setAsset(address(cake), 1_000_000e18, 1 days, type(uint128).max);
        vault.setAsset(address(0), 100 ether, 1 days, type(uint128).max);
        vault.addDestination(address(v2));
        vault.addDestination(address(v3));
        vault.addDestination(friend);

        (address[] memory targets, bytes4[] memory sels) = _tradingCalls();
        pid = vault.createPolicy(vm.addr(OP_PK), 0, 10 ether, policyGuard);
        vault.setAgent(pid, vm.addr(OP_PK), true, 0);
        vault.setSessionManager(manager);
        vault.setEnvelope(ENV, true, 1 days, 10 ether);
        vault.setEnvelope(ENV_NOGUARD, true, 1 days, 10 ether);
        for (uint256 i = 0; i < targets.length; i++) {
            vault.setCall(pid, targets[i], sels[i], true);
            vault.setEnvelopeCall(ENV, targets[i], sels[i], true);
            vault.setEnvelopeCall(ENV_NOGUARD, targets[i], sels[i], true);
        }
        vault.setEnvelopeCall(ENV_NOGUARD, friend, bytes4(0), true);
        address[4] memory assets = [address(usdt), address(wbnb), address(cake), address(0)];
        uint128[4] memory caps = [uint128(10_000e6), 50e18, 100_000e18, 10 ether];
        for (uint256 i = 0; i < 4; i++) {
            vault.setEnvelopeBudgetCap(ENV, assets[i], caps[i]);
            vault.setEnvelopeBudgetCap(ENV_NOGUARD, assets[i], caps[i]);
        }
        vault.setEnvelopeGuard(ENV, address(guard));
        vault.finalizeSetup();
        vm.stopPrank();

        usdt.mint(address(vault), 100_000e6);
        wbnb.mint(address(vault), 100e18);
        cake.mint(address(vault), 100_000e18);
        vm.deal(address(vault), 50 ether);
    }

    // ------------------------------------------------------------------ batch helpers

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _path3(address a, address b, address c) internal pure returns (address[] memory p) {
        p = new address[](3);
        p[0] = a;
        p[1] = b;
        p[2] = c;
    }

    /// approve -> swap -> reset allowance (the vault demands zero allowances after every batch)
    function _approveSwap(address token, address router, uint256 amount, uint256 value, bytes memory swapData)
        internal
        pure
        returns (EPKVault.Call[] memory c)
    {
        c = new EPKVault.Call[](3);
        c[0] = EPKVault.Call(token, 0, abi.encodeCall(IERC20.approve, (router, amount)));
        c[1] = EPKVault.Call(router, value, swapData);
        c[2] = EPKVault.Call(token, 0, abi.encodeCall(IERC20.approve, (router, 0)));
    }

    function _one(address target, uint256 value, bytes memory data) internal pure returns (EPKVault.Call[] memory c) {
        c = new EPKVault.Call[](1);
        c[0] = EPKVault.Call(target, value, data);
    }

    function _v2ExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address to)
        internal
        view
        returns (EPKVault.Call[] memory)
    {
        bytes memory d = abi.encodeCall(
            MockV2Router.swapExactTokensForTokens, (amountIn, minOut, _path(tokenIn, tokenOut), to, _now() + 5 minutes)
        );
        return _approveSwap(tokenIn, address(v2), amountIn, 0, d);
    }

    function _exec(uint256 policyId, uint256 pk, EPKVault.Call[] memory calls) internal {
        uint256 deadline = _now() + 1 hours;
        bytes32 d = vault.getExecuteDigest(policyId, vm.addr(pk), calls, vault.nonces(policyId), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        vm.prank(vm.addr(pk));
        vault.execute(policyId, calls, deadline, abi.encodePacked(r, s, v), "");
    }

    function _execFails(uint256 policyId, uint256 pk, EPKVault.Call[] memory calls, bytes memory err) internal {
        uint256 deadline = _now() + 1 hours;
        bytes32 d = vault.getExecuteDigest(policyId, vm.addr(pk), calls, vault.nonces(policyId), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        vm.expectRevert(err);
        vm.prank(vm.addr(pk));
        vault.execute(policyId, calls, deadline, abi.encodePacked(r, s, v), "");
    }

    function _execFailsWith(uint256 policyId, uint256 pk, EPKVault.Call[] memory calls, bytes4 selector) internal {
        uint256 deadline = _now() + 1 hours;
        bytes32 d = vault.getExecuteDigest(policyId, vm.addr(pk), calls, vault.nonces(policyId), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        vm.expectPartialRevert(selector);
        vm.prank(vm.addr(pk));
        vault.execute(policyId, calls, deadline, abi.encodePacked(r, s, v), "");
    }

    function _openSession(uint256 envelopeId) internal returns (uint256 sid) {
        address agent = vm.addr(AGENT_PK);
        vm.prank(manager);
        sid = vault.openSession(envelopeId, agent, agent, uint48(_now() + 1 hours));
    }
}
