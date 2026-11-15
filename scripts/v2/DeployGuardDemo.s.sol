// SPDX-License-Identifier: LicenseRef-IBITI-EPK-1.0
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
import {EPKFixedPriceFeed} from "./demo/EPKFixedPriceFeed.sol";
import {EPKDemoNetwork} from "./demo/EPKDemoNetwork.sol";

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

interface IPancakeFactoryV2 {
    function getPair(address a, address b) external view returns (address);
}

interface IPancakePairV2 {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

/// @notice The third-party contracts of each test network, and the guard demo's tUSD/WBNB pool on the real
///         PancakeSwap V2 router. tUSD is the demo's test stablecoin worth $1 that only the demo admin can mint,
///         so only the admin can move this pool's price: `_alignPool` keeps it at the BNB price the guard reads,
///         so that fair trades exist when the demo runs.
abstract contract GuardDemoPool is Script {
    uint256 internal constant BSC_TESTNET = 97;
    uint256 internal constant OPBNB_TESTNET = 5611;
    /// Chainlink BNB / USD on BSC Testnet. opBNB has no Chainlink price feeds: there the guard reads a fixed
    /// test price copied from this feed when the demo is deployed.
    address internal constant BSC_CHAINLINK_BNB_USD = 0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526;

    function _onlyGuardNetworks() internal view {
        // EPK is not audited: these scripts refuse to run on any mainnet
        require(block.chainid == BSC_TESTNET || block.chainid == OPBNB_TESTNET, "EPK guard demo: BSC Testnet or opBNB Testnet only");
    }

    // PancakeSwap V2 router (addresses as in PancakeSwap's own SDK, @pancakeswap/smart-router V2_ROUTER_ADDRESS)
    function _router() internal view returns (address) {
        if (block.chainid == OPBNB_TESTNET) return 0x62FF25CFD64E55673168c3656f4902bD7Aa5F0f4;
        return 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
    }

    // PancakeSwap V2 factory (@pancakeswap/v2-sdk FACTORY_ADDRESS_MAP)
    function _pancakeFactory() internal view returns (address) {
        if (block.chainid == OPBNB_TESTNET) return 0x776e4bD2f72de2176A59465e316335aaf8ed4E8F;
        return 0x6725F303b657a9451d8BA641348b6761A6CC7a17;
    }

    /// wrapped BNB (the router's WETH())
    function _wbnb() internal view returns (address) {
        if (block.chainid == OPBNB_TESTNET) return 0x4200000000000000000000000000000000000006;
        return 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    }

    function _pair2(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    /// @dev Call inside a broadcast of the demo admin key (the only tUSD minter). Moves the pool to the price of
    ///      `bnbUsd` (tUSD = $1) if it is more than 0.1 % away: sells freshly minted tUSD into it, or buys tUSD
    ///      with BNB. Returns what it put in (0, 0 = the pool was already at the price).
    function _alignPool(address admin, address tusd, address bnbUsd) internal returns (uint256 tusdIn, uint256 bnbIn) {
        address router = _router();
        address wbnb = _wbnb();
        address pair = IPancakeFactoryV2(_pancakeFactory()).getPair(wbnb, tusd);
        (uint112 r0, uint112 r1,) = IPancakePairV2(pair).getReserves();
        (uint256 rb, uint256 rt) =
            IPancakePairV2(pair).token0() == wbnb ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        (, int256 answer,,,) = IChainlinkFeed(bnbUsd).latestRoundData(); // USD per BNB, 8 decimals
        require(answer > 0, "no BNB price");
        uint256 k = rb * rt;
        uint256 rtTarget = Math.sqrt(k * uint256(answer) / 1e8); // tUSD reserve at the target price
        uint256 rbTarget = Math.sqrt(k * 1e8 / uint256(answer)); // WBNB reserve at the target price
        if (rtTarget > rt + rt / 1000) {
            tusdIn = rtTarget - rt;
            EPKTestUSD(tusd).mint(admin, tusdIn);
            IERC20(tusd).approve(router, tusdIn);
            IPancakeRouterV2(router).swapExactTokensForETH(tusdIn, 0, _pair2(tusd, wbnb), admin, block.timestamp + 600);
        } else if (rbTarget > rb + rb / 1000) {
            bnbIn = rbTarget - rb;
            IPancakeRouterV2(router).swapExactETHForTokens{value: bnbIn}(0, _pair2(wbnb, tusd), admin, block.timestamp + 600);
        }
        console2.log("pool aligned to the guard's BNB/USD (8 dec):", uint256(answer));
        console2.log("  tUSD sold into the pool:", tusdIn);
        console2.log("  BNB  sold into the pool:", bnbIn);
    }
}

/// @title EPK guard demo on the current EPKVault release (BSC Testnet or opBNB Testnet)
/// @notice A vault created through the PUBLIC factory of the current release (BSC Testnet: the SDK's
///         `networks.bscTestnet.epk.factory`, read from deployments/bsc-testnet/epk-release.json; opBNB Testnet:
///         `networks.opbnbTestnet.epk.factory`, from deployments/opbnb-testnet/epk-v2.json; the registries run the
///         5-minute public-test-network clocks), guarded by a DexGuard, ThreatFeed V2 and CompositeGuard deployed
///         from this repository's code, on the real PancakeSwap V2 router of the network.
///         BSC Testnet: prices from the real Chainlink BNB/USD and BUSD/USD feeds; tUSD and its fixed $1 feed
///         already exist there. opBNB Testnet has no Chainlink feeds, so this script first deploys tUSD, its
///         fixed $1 feed and a fixed BNB/USD test price copied from Chainlink on BSC Testnet (round recorded),
///         and seeds a tUSD/WBNB pool at that price. It also wires a second DexGuard to the official opBNB
///         price oracle (Binance Oracle BNB/USD), to show what a guard does when an oracle stops updating.
///         Keys: V21_* in the local .env (testnet only). Writes deployments/<network>/epk-guards.json.
/// forge script scripts/v2/DeployGuardDemo.s.sol:DeployGuardDemo --rpc-url $RPC --broadcast --slow
contract DeployGuardDemo is GuardDemoPool {
    // BSC Testnet: third-party BUSD and Chainlink feeds; tUSD and its feed from the first guard demo
    address internal constant BSC_BUSD = 0x78867BbEeF44f2326bF8DDd1941a4439382EF2A7;
    address internal constant BSC_BUSD_USD = 0x9331b55D9830EF609A2aBCfAc0FBCE050A52fdEa; // Chainlink, testnet
    address internal constant BSC_TUSD = 0xc58699856ED5c978F7bf47e46650Bdb23d9bB119; // EPKTestUSD (minter: demo admin)
    address internal constant BSC_TUSD_FEED = 0xD246D8d4d58d7b444159Bd8cFf9B6fb00f27105C; // fixed $1 test feed
    /// opBNB Testnet: Binance Oracle BNB/USD feed adapter (oracle.binance.com, "opBNB Testnet Feed addresses")
    address internal constant OPBNB_BINANCE_ORACLE_BNB_USD = 0x73110e8602930f01bb584Bc683C5Aa2Fb4D42419;

    uint256 internal constant VAULT_BNB = 0.002 ether;
    uint256 internal constant POOL_BNB = 0.03 ether; // opBNB: depth of the new tUSD/WBNB pool
    uint256 internal constant DELAY = 5 minutes; // the test-network minimum (mainnet: at least 1 hour)
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

    /// prices and tokens of this network
    struct Market {
        address tusd;
        address tusdFeed;
        address bnbUsd; // the BNB/USD feed the guard reads
        address busd; // BSC Testnet only: a third-party stablecoin with a real WBNB pool
        address busdUsd;
        uint256 bnbUsdRound; // opBNB: the Chainlink round on BSC Testnet the fixed price was copied from
        int256 bnbUsdAnswer;
        address oracleGuard; // opBNB: a DexGuard on the Binance Oracle feed
        uint256 oraclePolicy;
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

    /// @dev The latest Chainlink BNB/USD round on BSC Testnet, read through a BSC Testnet node.
    function _bscChainlinkBnbUsd() internal returns (uint80 round, int256 answer) {
        string memory node = vm.envOr("BSC_RPC_URL", string("https://bsc-testnet-rpc.publicnode.com"));
        bytes memory ret = vm.rpc(
            node,
            "eth_call",
            string.concat('[{"to":"', vm.toString(BSC_CHAINLINK_BNB_USD), '","data":"0xfeaf968c"},"latest"]')
        );
        uint256 updatedAt;
        (round, answer,, updatedAt,) = abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
        require(answer > 0 && updatedAt + 1 days > vm.unixTime() / 1000, "no fresh Chainlink BNB price on BSC Testnet");
    }

    /// @dev opBNB Testnet, inside the admin's broadcast: tUSD, the test prices and the tUSD/WBNB pool.
    function _opbnbMarket(address admin) internal returns (Market memory m) {
        (uint80 round, int256 answer) = _bscChainlinkBnbUsd();
        m.bnbUsdRound = round;
        m.bnbUsdAnswer = answer;
        m.tusd = address(new EPKTestUSD());
        m.tusdFeed = address(new EPKFixedPriceFeed(8, 1e8, "tUSD / USD: fixed $1 test price"));
        m.bnbUsd = address(
            new EPKFixedPriceFeed(
                8, answer, string.concat("BNB / USD test price: Chainlink BNB/USD on BSC Testnet, round ", vm.toString(uint256(round)))
            )
        );
        // a new tUSD/WBNB pool on the real PancakeSwap V2 router, at that price
        uint256 tusdForPool = POOL_BNB * uint256(answer) / 1e8;
        EPKTestUSD(m.tusd).mint(admin, tusdForPool);
        IERC20(m.tusd).approve(_router(), tusdForPool);
        IPancakeRouterV2(_router()).addLiquidityETH{value: POOL_BNB}(
            m.tusd, tusdForPool, tusdForPool, POOL_BNB, admin, block.timestamp + 600
        );
    }

    function run() external {
        _onlyGuardNetworks();
        bool opbnb = block.chainid == OPBNB_TESTNET;
        // the public stack of the current release: BSC Testnet's release record, opBNB Testnet's stack record
        string memory relPath = EPKDemoNetwork.file(opbnb ? "epk-v2.json" : "epk-release.json");
        string memory rel = vm.readFile(relPath);
        EPKVaultFactory factory = EPKVaultFactory(vm.parseJsonAddress(rel, ".factory"));
        address impl = vm.parseJsonAddress(rel, ".implementation");
        require(factory.implementation() == impl, "public factory is not on the current release");
        Roles memory r = _roles();
        address router = _router();
        address wbnb = _wbnb();
        vm.startBroadcast(vm.envUint("V21_ADMIN_PRIVATE_KEY"));

        // 1) tokens, prices and the demo pool at the guard's BNB price
        Market memory m;
        uint256 alignTusd;
        uint256 alignBnb;
        if (opbnb) {
            m = _opbnbMarket(r.admin);
        } else {
            m.tusd = BSC_TUSD;
            m.tusdFeed = BSC_TUSD_FEED;
            m.bnbUsd = BSC_CHAINLINK_BNB_USD;
            m.busd = BSC_BUSD;
            m.busdUsd = BSC_BUSD_USD;
            (alignTusd, alignBnb) = _alignPool(r.admin, m.tusd, m.bnbUsd);
        }

        // 2) guards from this repository's code
        DexGuard.RouterInit[] memory routers = new DexGuard.RouterInit[](1);
        routers[0] = DexGuard.RouterInit(router, DexGuard.RouterKind.V2);
        DexGuard.TokenInit[] memory tokens = new DexGuard.TokenInit[](opbnb ? 2 : 3);
        tokens[0] = DexGuard.TokenInit(wbnb, m.bnbUsd, 1 days, 0.001 ether, 1e8, 100_000e8);
        tokens[1] = DexGuard.TokenInit(m.tusd, m.tusdFeed, 1 days, 10e18, 0.5e8, 2e8);
        if (!opbnb) tokens[2] = DexGuard.TokenInit(m.busd, m.busdUsd, 2 days, 10e18, 0.5e8, 2e8);
        DexGuard dex = new DexGuard(wbnb, 100, 10 minutes, routers, tokens);
        ThreatFeedGuard feed = new ThreatFeedGuard(r.admin, 1 hours);
        feed.setBlocker(r.responder, true);
        address[] memory kids = new address[](2);
        kids[0] = address(feed); // blocklist first, then the DEX rules
        kids[1] = address(dex);
        CompositeGuard guard = new CompositeGuard(kids, new bool[](2));
        if (opbnb) {
            // the same DEX rules, priced by the official opBNB oracle (Binance Oracle BNB/USD), with 2 days of
            // tolerance although its testnet feed is documented to update every 24 hours
            DexGuard.TokenInit[] memory oracleTokens = new DexGuard.TokenInit[](2);
            oracleTokens[0] = DexGuard.TokenInit(wbnb, OPBNB_BINANCE_ORACLE_BNB_USD, 2 days, 0.001 ether, 1e8, 100_000e8);
            oracleTokens[1] = tokens[1];
            m.oracleGuard = address(new DexGuard(wbnb, 100, 10 minutes, routers, oracleTokens));
        }

        // 3) a new vault on the current release, created through the public factory like any integrator's vault
        address[] memory guardians = new address[](2);
        guardians[0] = r.g1;
        guardians[1] = r.g2;
        EPKVault vault = EPKVault(
            payable(factory.createVault(guardians, DELAY, r.recovery, keccak256(abi.encode("EPK guard demo vault", block.number))))
        );
        vault.setAsset(address(0), uint128(VAULT_BNB), 1 days, type(uint128).max);
        vault.setAsset(m.tusd, 20e18, 1 days, type(uint128).max);
        if (!opbnb) vault.setAsset(m.busd, 20e18, 1 days, type(uint128).max);
        vault.addDestination(router);
        vault.addDestination(r.supplier);
        vault.setSessionManager(r.manager);

        uint256 pid = vault.createPolicy(r.operator, 0, 0.001 ether, address(guard));
        vault.setAgent(pid, r.operator, true, 0);
        vault.setCall(pid, router, IPancakeRouterV2.swapExactETHForTokens.selector, true);
        vault.setCall(pid, router, IPancakeRouterV2.swapExactTokensForETH.selector, true);
        vault.setCall(pid, router, IPancakeRouterV2.swapExactETHForTokensSupportingFeeOnTransferTokens.selector, true);
        vault.setCall(pid, m.tusd, IERC20.approve.selector, true);
        vault.setCall(pid, m.tusd, IERC20.transfer.selector, true);
        if (opbnb) {
            // a second trading policy for the same operator key, guarded by the oracle-priced DexGuard
            m.oraclePolicy = vault.createPolicy(r.operator, 0, 0.001 ether, m.oracleGuard);
            vault.setAgent(m.oraclePolicy, r.operator, true, 0);
            vault.setCall(m.oraclePolicy, router, IPancakeRouterV2.swapExactETHForTokens.selector, true);
        }

        uint256[2] memory envs = [GUARDED, UNGUARDED];
        for (uint256 i = 0; i < 2; i++) {
            vault.setEnvelope(envs[i], true, 1 days, 0.001 ether);
            vault.setEnvelopeCall(envs[i], router, IPancakeRouterV2.swapExactETHForTokens.selector, true);
            vault.setEnvelopeCall(envs[i], router, IPancakeRouterV2.swapExactTokensForETH.selector, true);
            vault.setEnvelopeCall(envs[i], m.tusd, IERC20.approve.selector, true);
            vault.setEnvelopeBudgetCap(envs[i], address(0), 0.001 ether);
            vault.setEnvelopeBudgetCap(envs[i], m.tusd, 5e18);
        }
        vault.setEnvelopeGuard(GUARDED, address(guard));
        vault.finalizeSetup();

        EPKTestUSD(m.tusd).mint(address(vault), 50e18);
        (bool sent,) = payable(address(vault)).call{value: VAULT_BNB}("");
        require(sent, "fund vault");
        vm.stopBroadcast();
        require(vault.vaultVersion() == vm.parseJsonUint(rel, ".version"), "vault is not on the current release");

        string memory o = "guards";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "version", vault.vaultVersion());
        vm.serializeAddress(o, "implementation", impl);
        vm.serializeAddress(o, "registry", factory.registry());
        vm.serializeAddress(o, "factory", address(factory));
        vm.serializeUint(o, "delay", DELAY);
        vm.serializeAddress(o, "vault", address(vault));
        vm.serializeAddress(o, "dexGuard", address(dex));
        vm.serializeAddress(o, "threatFeed", address(feed));
        vm.serializeAddress(o, "compositeGuard", address(guard));
        vm.serializeAddress(o, "tusd", m.tusd);
        vm.serializeAddress(o, "tusdFeed", m.tusdFeed);
        vm.serializeAddress(o, "router", router);
        vm.serializeAddress(o, "pancakeFactory", _pancakeFactory());
        vm.serializeAddress(o, "wbnb", wbnb);
        vm.serializeAddress(o, "bnbUsdFeed", m.bnbUsd);
        if (opbnb) {
            vm.serializeAddress(o, "bnbUsdSource", BSC_CHAINLINK_BNB_USD);
            vm.serializeUint(o, "bnbUsdSourceChainId", BSC_TESTNET);
            vm.serializeUint(o, "bnbUsdSourceRound", m.bnbUsdRound);
            vm.serializeInt(o, "bnbUsdAnswer", m.bnbUsdAnswer);
            vm.serializeUint(o, "poolBnb", POOL_BNB);
            vm.serializeAddress(o, "oracleGuard", m.oracleGuard);
            vm.serializeAddress(o, "oracleFeed", OPBNB_BINANCE_ORACLE_BNB_USD);
            vm.serializeUint(o, "oraclePolicy", m.oraclePolicy);
        } else {
            vm.serializeAddress(o, "busd", m.busd);
            vm.serializeAddress(o, "busdUsdFeed", m.busdUsd);
        }
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
        vm.writeJson(out, EPKDemoNetwork.file("epk-guards.json"));

        console2.log("guard demo vault:", address(vault), "version", vault.vaultVersion());
        console2.log("DexGuard:", address(dex));
        console2.log("CompositeGuard (ThreatFeed + DexGuard):", address(guard));
        if (opbnb) console2.log("DexGuard on Binance Oracle BNB/USD:", m.oracleGuard);
    }
}
