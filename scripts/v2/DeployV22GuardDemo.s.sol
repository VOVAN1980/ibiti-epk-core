// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EPKVault} from "../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../contracts/v2/EPKVaultFactory.sol";
import {DexGuard, IChainlinkFeed} from "../../contracts/v2/guards/DexGuard.sol";
import {ThreatFeedGuard} from "../../contracts/v2/guards/ThreatFeedGuard.sol";
import {CompositeGuard} from "../../contracts/v2/guards/CompositeGuard.sol";
import {EPKTestUSD} from "./demo/EPKTestUSD.sol";
import {IPancakeRouterV2} from "./DeployV21Demo.s.sol";

interface IPancakeFactoryV2 {
    function getPair(address a, address b) external view returns (address);
}

interface IPancakePairV2 {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

/// @notice The guard demo's tUSD/WBNB pool on the real PancakeSwap V2 testnet router (seeded by the 2.1 demo
///         on 2026-11-07). tUSD is a test stablecoin worth $1 that only the demo admin can mint, so only the
///         admin can move this pool's price: `_alignPool` moves it back to the Chainlink BNB price, so that
///         fair trades exist when the demo runs.
abstract contract GuardDemoPool is Script {
    address internal constant ROUTER = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1; // PancakeSwap V2, testnet
    address internal constant PANCAKE_FACTORY = 0x6725F303b657a9451d8BA641348b6761A6CC7a17;
    address internal constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    address internal constant BNB_USD = 0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526; // Chainlink, testnet
    address internal constant TUSD = 0xc58699856ED5c978F7bf47e46650Bdb23d9bB119; // EPKTestUSD (minter: demo admin)

    function _pair2(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    /// @dev Call inside a broadcast of the demo admin key (the only tUSD minter). Moves the pool to the
    ///      Chainlink price (tUSD = $1) if it is more than 0.1 % away: sells freshly minted tUSD into it, or
    ///      buys tUSD with BNB. Returns what it put in (0, 0 = the pool was already at the price).
    function _alignPool(address admin) internal returns (uint256 tusdIn, uint256 bnbIn) {
        address pair = IPancakeFactoryV2(PANCAKE_FACTORY).getPair(WBNB, TUSD);
        (uint112 r0, uint112 r1,) = IPancakePairV2(pair).getReserves();
        (uint256 rb, uint256 rt) =
            IPancakePairV2(pair).token0() == WBNB ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        (, int256 answer,,,) = IChainlinkFeed(BNB_USD).latestRoundData(); // USD per BNB, 8 decimals
        require(answer > 0, "no BNB price");
        uint256 k = rb * rt;
        uint256 rtTarget = Math.sqrt(k * uint256(answer) / 1e8); // tUSD reserve at the target price
        uint256 rbTarget = Math.sqrt(k * 1e8 / uint256(answer)); // WBNB reserve at the target price
        if (rtTarget > rt + rt / 1000) {
            tusdIn = rtTarget - rt;
            EPKTestUSD(TUSD).mint(admin, tusdIn);
            IERC20(TUSD).approve(ROUTER, tusdIn);
            IPancakeRouterV2(ROUTER).swapExactTokensForETH(tusdIn, 0, _pair2(TUSD, WBNB), admin, block.timestamp + 600);
        } else if (rbTarget > rb + rb / 1000) {
            bnbIn = rbTarget - rb;
            IPancakeRouterV2(ROUTER).swapExactETHForTokens{value: bnbIn}(0, _pair2(WBNB, TUSD), admin, block.timestamp + 600);
        }
        console2.log("pool aligned to Chainlink BNB/USD (8 dec):", uint256(answer));
        console2.log("  tUSD sold into the pool:", tusdIn);
        console2.log("  BNB  sold into the pool:", bnbIn);
    }
}

/// @title EPK guard demo on EPKVault 2.2.0 — the current guard demo (BSC Testnet)
/// @notice A new vault created through the PUBLIC 2.2.0 factory (the SDK's `networks.bscTestnet.epk.factory`,
///         whose registry runs the 5-minute public-test-network clocks), guarded by a DexGuard, ThreatFeed V2
///         and CompositeGuard deployed from this repository's current code (with the 2026-11-08 guard fixes).
///         Same rules, tokens, pool and role keys as the 2.1 guard demo, whose vault and proofs stay as they
///         are (history). Keys: V21_* in the local .env (testnet only).
/// forge script scripts/v2/DeployV22GuardDemo.s.sol:DeployV22GuardDemo --rpc-url $BSC_RPC_URL --broadcast --slow
contract DeployV22GuardDemo is GuardDemoPool {
    string internal constant OUT = "deployments/bsc-testnet/epk-v2.2-guards.json";

    EPKVaultFactory internal constant FACTORY = EPKVaultFactory(0xA128110b6C89E3A55E1F7815b75D48fcb124EB48);
    address internal constant IMPL_2_2_0 = 0xD5cb4eB76cBABF55769f8c4ebfFb13754b1E5Ffd;
    address internal constant BUSD = 0x78867BbEeF44f2326bF8DDd1941a4439382EF2A7;
    address internal constant BUSD_USD = 0x9331b55D9830EF609A2aBCfAc0FBCE050A52fdEa; // Chainlink, testnet
    address internal constant TUSD_FEED = 0xD246D8d4d58d7b444159Bd8cFf9B6fb00f27105C; // fixed $1 test feed

    uint256 internal constant VAULT_BNB = 0.004 ether;
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
        // EPK is not audited: these scripts refuse to run on any mainnet
        require(block.chainid == 97, "BSC Testnet only");
        require(FACTORY.implementation() == IMPL_2_2_0, "public factory is not on 2.2.0");
        Roles memory r = _roles();
        vm.startBroadcast(vm.envUint("V21_ADMIN_PRIVATE_KEY"));

        // 1) the demo pool back at the Chainlink price
        (uint256 alignTusd, uint256 alignBnb) = _alignPool(r.admin);

        // 2) guards from this repository's current code (same rules as the 2.1 demo)
        DexGuard.RouterInit[] memory routers = new DexGuard.RouterInit[](1);
        routers[0] = DexGuard.RouterInit(ROUTER, DexGuard.RouterKind.V2);
        DexGuard.TokenInit[] memory tokens = new DexGuard.TokenInit[](3);
        tokens[0] = DexGuard.TokenInit(WBNB, BNB_USD, 1 days, 0.001 ether, 1e8, 100_000e8);
        tokens[1] = DexGuard.TokenInit(BUSD, BUSD_USD, 2 days, 10e18, 0.5e8, 2e8);
        tokens[2] = DexGuard.TokenInit(TUSD, TUSD_FEED, 1 days, 10e18, 0.5e8, 2e8);
        DexGuard dex = new DexGuard(WBNB, 100, 10 minutes, routers, tokens);
        ThreatFeedGuard feed = new ThreatFeedGuard(r.admin, 1 hours);
        feed.setBlocker(r.responder, true);
        address[] memory kids = new address[](2);
        kids[0] = address(feed); // blocklist first, then the DEX rules
        kids[1] = address(dex);
        CompositeGuard guard = new CompositeGuard(kids, new bool[](2));

        // 3) a new EPKVault 2.2.0, created through the public factory like any integrator's vault
        address[] memory guardians = new address[](2);
        guardians[0] = r.g1;
        guardians[1] = r.g2;
        EPKVault vault = EPKVault(
            payable(FACTORY.createVault(guardians, 1 hours, r.recovery, keccak256("EPK 2.2 guard demo vault")))
        );
        vault.setAsset(address(0), 0.004 ether, 1 days, type(uint128).max);
        vault.setAsset(TUSD, 20e18, 1 days, type(uint128).max);
        vault.setAsset(BUSD, 20e18, 1 days, type(uint128).max);
        vault.addDestination(ROUTER);
        vault.addDestination(r.supplier);
        vault.setSessionManager(r.manager);

        uint256 pid = vault.createPolicy(r.operator, 0, 0.001 ether, address(guard));
        vault.setAgent(pid, r.operator, true, 0);
        vault.setCall(pid, ROUTER, IPancakeRouterV2.swapExactETHForTokens.selector, true);
        vault.setCall(pid, ROUTER, IPancakeRouterV2.swapExactTokensForETH.selector, true);
        vault.setCall(pid, ROUTER, IPancakeRouterV2.swapExactETHForTokensSupportingFeeOnTransferTokens.selector, true);
        vault.setCall(pid, TUSD, IERC20.approve.selector, true);
        vault.setCall(pid, TUSD, IERC20.transfer.selector, true);

        uint256[2] memory envs = [GUARDED, UNGUARDED];
        for (uint256 i = 0; i < 2; i++) {
            vault.setEnvelope(envs[i], true, 1 days, 0.001 ether);
            vault.setEnvelopeCall(envs[i], ROUTER, IPancakeRouterV2.swapExactETHForTokens.selector, true);
            vault.setEnvelopeCall(envs[i], ROUTER, IPancakeRouterV2.swapExactTokensForETH.selector, true);
            vault.setEnvelopeCall(envs[i], TUSD, IERC20.approve.selector, true);
            vault.setEnvelopeBudgetCap(envs[i], address(0), 0.001 ether);
            vault.setEnvelopeBudgetCap(envs[i], TUSD, 5e18);
        }
        vault.setEnvelopeGuard(GUARDED, address(guard));
        vault.finalizeSetup();

        EPKTestUSD(TUSD).mint(address(vault), 50e18);
        (bool sent,) = payable(address(vault)).call{value: VAULT_BNB}("");
        require(sent, "fund vault");
        vm.stopBroadcast();
        require(vault.vaultVersion() == 20_200, "vault is not on 2.2.0");

        string memory o = "v22g";
        vm.serializeAddress(o, "implementation_2_2_0", IMPL_2_2_0);
        vm.serializeAddress(o, "registry", FACTORY.registry());
        vm.serializeAddress(o, "factory", address(FACTORY));
        vm.serializeAddress(o, "vault", address(vault));
        vm.serializeAddress(o, "dexGuard", address(dex));
        vm.serializeAddress(o, "threatFeed", address(feed));
        vm.serializeAddress(o, "compositeGuard", address(guard));
        vm.serializeAddress(o, "tusd", TUSD);
        vm.serializeAddress(o, "tusdFeed", TUSD_FEED);
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
        vm.serializeUint(o, "alignTusdIn", alignTusd);
        vm.serializeUint(o, "alignBnbIn", alignBnb);
        vm.serializeUint(o, "policy", pid);
        vm.serializeUint(o, "envelopeGuarded", GUARDED);
        vm.serializeUint(o, "envelopeUnguarded", UNGUARDED);
        string memory out = vm.serializeUint(o, "createdAtBlock", block.number);
        vm.writeJson(out, OUT);

        console2.log("EPKVault 2.2.0 guard demo vault:", address(vault));
        console2.log("DexGuard:", address(dex));
        console2.log("CompositeGuard (ThreatFeed + DexGuard):", address(guard));
    }
}
