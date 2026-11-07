// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EPKVault} from "../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../contracts/v2/EPKVaultFactory.sol";
import {EPKRegistry} from "../../contracts/v2/EPKRegistry.sol";
import {DexGuard, IChainlinkFeed} from "../../contracts/v2/guards/DexGuard.sol";
import {ThreatFeedGuard} from "../../contracts/v2/guards/ThreatFeedGuard.sol";
import {CompositeGuard} from "../../contracts/v2/guards/CompositeGuard.sol";
import {EPKTestUSD} from "./demo/EPKTestUSD.sol";
import {EPKFixedPriceFeed} from "./demo/EPKFixedPriceFeed.sol";

interface IPancakeRouterV2 {
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

/// @title EPK 2.1 guard demo — a SEPARATE stack on BSC Testnet
/// @notice Its own registry, factory and EPKVault 2.1.0 (the 2.0.x demo vault and its 2.0.1 upgrade are
///         not touched), DexGuard on the real PancakeSwap V2 testnet router with real Chainlink BNB/USD and
///         BUSD/USD feeds, ThreatFeed V2 and a CompositeGuard. A small tUSD/BNB pool is seeded at the
///         Chainlink BNB price so that fair trades exist; tUSD is the demo's own test stablecoin with a
///         fixed $1 test feed. Keys: V21_* in the local .env (testnet only).
/// forge script scripts/v2/DeployV21Demo.s.sol:DeployV21Demo --rpc-url $BSC_RPC_URL --broadcast --slow
contract DeployV21Demo is Script {
    string internal constant OUT = "deployments/bsc-testnet/epk-v2.1.json";

    address internal constant ROUTER = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1; // PancakeSwap V2, testnet
    address internal constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    address internal constant BUSD = 0x78867BbEeF44f2326bF8DDd1941a4439382EF2A7;
    address internal constant BNB_USD = 0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526; // Chainlink, testnet
    address internal constant BUSD_USD = 0x9331b55D9830EF609A2aBCfAc0FBCE050A52fdEa; // Chainlink, testnet

    uint256 internal constant POOL_BNB = 0.03 ether;
    uint256 internal constant VAULT_BNB = 0.006 ether;
    uint256 internal constant GUARDED = 1; // session envelope with the guard
    uint256 internal constant UNGUARDED = 2; // same calls, no guard (to show GuardRequired)

    struct Roles {
        address admin;
        address g1;
        address g2;
        address recovery;
        address manager;
        address operator;
        address agent;
        address responder;
        address supplier;
        address attacker;
    }

    function _roles() internal view returns (Roles memory r) {
        r.admin = vm.addr(vm.envUint("V21_ADMIN_PRIVATE_KEY"));
        r.g1 = vm.addr(vm.envUint("V21_GUARDIAN1_PRIVATE_KEY"));
        r.g2 = vm.addr(vm.envUint("V21_GUARDIAN2_PRIVATE_KEY"));
        r.recovery = vm.addr(vm.envUint("V21_RECOVERY_PRIVATE_KEY"));
        r.manager = vm.addr(vm.envUint("V21_SESSION_MANAGER_PRIVATE_KEY"));
        r.operator = vm.addr(vm.envUint("V21_OPERATOR_PRIVATE_KEY"));
        r.agent = vm.addr(vm.envUint("V21_AGENT_PRIVATE_KEY"));
        r.responder = vm.addr(vm.envUint("V21_RESPONDER_PRIVATE_KEY"));
        r.supplier = vm.addr(vm.envUint("V21_SUPPLIER_PRIVATE_KEY"));
        r.attacker = vm.addr(vm.envUint("V21_ATTACKER_PRIVATE_KEY"));
    }

    function run() external {
        require(block.chainid == 97, "BSC Testnet only");
        Roles memory r = _roles();
        vm.startBroadcast(vm.envUint("V21_ADMIN_PRIVATE_KEY"));

        // 1) a separate 2.1.0 stack
        EPKVault impl = new EPKVault();
        EPKRegistry registry = new EPKRegistry(r.admin, address(impl));
        EPKVaultFactory factory = new EPKVaultFactory(address(impl), address(registry));

        // 2) test stablecoin, its fixed test feed, and a fair tUSD/BNB pool on the real router
        EPKTestUSD tusd = new EPKTestUSD();
        EPKFixedPriceFeed tusdFeed = new EPKFixedPriceFeed(8, 1e8, "tUSD / USD (test, fixed $1)");
        (, int256 bnbUsd,,,) = IChainlinkFeed(BNB_USD).latestRoundData();
        uint256 tusdForPool = POOL_BNB * uint256(bnbUsd) / 1e8;
        tusd.mint(r.admin, tusdForPool);
        tusd.approve(ROUTER, tusdForPool);
        IPancakeRouterV2(ROUTER).addLiquidityETH{value: POOL_BNB}(
            address(tusd), tusdForPool, tusdForPool, POOL_BNB, r.admin, block.timestamp + 600
        );

        // 3) guards
        DexGuard.RouterInit[] memory routers = new DexGuard.RouterInit[](1);
        routers[0] = DexGuard.RouterInit(ROUTER, DexGuard.RouterKind.V2);
        DexGuard.TokenInit[] memory tokens = new DexGuard.TokenInit[](3);
        tokens[0] = DexGuard.TokenInit(WBNB, BNB_USD, 1 days, 0.001 ether, 1e8, 100_000e8);
        tokens[1] = DexGuard.TokenInit(BUSD, BUSD_USD, 2 days, 10e18, 0.5e8, 2e8);
        tokens[2] = DexGuard.TokenInit(address(tusd), address(tusdFeed), 1 days, 10e18, 0.5e8, 2e8);
        DexGuard dex = new DexGuard(WBNB, 100, 10 minutes, routers, tokens);
        ThreatFeedGuard feed = new ThreatFeedGuard(r.admin, 1 hours);
        feed.setBlocker(r.responder, true);
        address[] memory kids = new address[](2);
        kids[0] = address(feed); // blocklist first, then the DEX rules
        kids[1] = address(dex);
        CompositeGuard guard = new CompositeGuard(kids, new bool[](2));

        // 4) a separate EPKVault 2.1.0
        address[] memory guardians = new address[](2);
        guardians[0] = r.g1;
        guardians[1] = r.g2;
        EPKVault vault =
            EPKVault(payable(factory.createVault(guardians, 1 hours, r.recovery, keccak256("EPK 2.1 guard demo vault"))));
        vault.setAsset(address(0), 0.004 ether, 1 days, type(uint128).max);
        vault.setAsset(address(tusd), 20e18, 1 days, type(uint128).max);
        vault.setAsset(BUSD, 20e18, 1 days, type(uint128).max);
        vault.addDestination(ROUTER);
        vault.addDestination(r.supplier);
        vault.setSessionManager(r.manager);

        uint256 pid = vault.createPolicy(r.operator, 0, 0.001 ether, address(guard));
        vault.setAgent(pid, r.operator, true, 0);
        vault.setCall(pid, ROUTER, IPancakeRouterV2.swapExactETHForTokens.selector, true);
        vault.setCall(pid, ROUTER, IPancakeRouterV2.swapExactTokensForETH.selector, true);
        vault.setCall(pid, ROUTER, IPancakeRouterV2.swapExactETHForTokensSupportingFeeOnTransferTokens.selector, true);
        vault.setCall(pid, address(tusd), IERC20.approve.selector, true);
        vault.setCall(pid, address(tusd), IERC20.transfer.selector, true);

        uint256[2] memory envs = [GUARDED, UNGUARDED];
        for (uint256 i = 0; i < 2; i++) {
            vault.setEnvelope(envs[i], true, 1 days, 0.001 ether);
            vault.setEnvelopeCall(envs[i], ROUTER, IPancakeRouterV2.swapExactETHForTokens.selector, true);
            vault.setEnvelopeCall(envs[i], ROUTER, IPancakeRouterV2.swapExactTokensForETH.selector, true);
            vault.setEnvelopeCall(envs[i], address(tusd), IERC20.approve.selector, true);
            vault.setEnvelopeBudgetCap(envs[i], address(0), 0.001 ether);
            vault.setEnvelopeBudgetCap(envs[i], address(tusd), 5e18);
        }
        vault.setEnvelopeGuard(GUARDED, address(guard));
        vault.finalizeSetup();

        tusd.mint(address(vault), 50e18);
        (bool sent,) = payable(address(vault)).call{value: VAULT_BNB}("");
        require(sent, "fund vault");
        vm.stopBroadcast();

        string memory o = "v21";
        vm.serializeAddress(o, "implementation_2_1_0", address(impl));
        vm.serializeAddress(o, "registry", address(registry));
        vm.serializeAddress(o, "factory", address(factory));
        vm.serializeAddress(o, "vault", address(vault));
        vm.serializeAddress(o, "dexGuard", address(dex));
        vm.serializeAddress(o, "threatFeed", address(feed));
        vm.serializeAddress(o, "compositeGuard", address(guard));
        vm.serializeAddress(o, "tusd", address(tusd));
        vm.serializeAddress(o, "tusdFeed", address(tusdFeed));
        vm.serializeAddress(o, "router", ROUTER);
        vm.serializeAddress(o, "wbnb", WBNB);
        vm.serializeAddress(o, "busd", BUSD);
        vm.serializeAddress(o, "bnbUsdFeed", BNB_USD);
        vm.serializeAddress(o, "busdUsdFeed", BUSD_USD);
        vm.serializeAddress(o, "admin", r.admin);
        vm.serializeAddress(o, "guardian1", r.g1);
        vm.serializeAddress(o, "guardian2", r.g2);
        vm.serializeAddress(o, "recovery", r.recovery);
        vm.serializeAddress(o, "sessionManager", r.manager);
        vm.serializeAddress(o, "operator", r.operator);
        vm.serializeAddress(o, "agent", r.agent);
        vm.serializeAddress(o, "responder", r.responder);
        vm.serializeAddress(o, "supplier", r.supplier);
        vm.serializeAddress(o, "attacker", r.attacker);
        vm.serializeUint(o, "policy", pid);
        vm.serializeUint(o, "envelopeGuarded", GUARDED);
        vm.serializeUint(o, "envelopeUnguarded", UNGUARDED);
        string memory out = vm.serializeUint(o, "createdAtBlock", block.number);
        vm.writeJson(out, OUT);

        console2.log("EPKVault 2.1.0 demo vault:", address(vault));
        console2.log("DexGuard:", address(dex));
        console2.log("CompositeGuard (ThreatFeed + DexGuard):", address(guard));
    }
}
