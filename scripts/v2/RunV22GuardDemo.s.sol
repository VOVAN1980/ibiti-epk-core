// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EPKVault} from "../../contracts/v2/EPKVault.sol";
import {DexGuard} from "../../contracts/v2/guards/DexGuard.sol";
import {ThreatFeedGuard} from "../../contracts/v2/guards/ThreatFeedGuard.sol";
import {GuardDemoPool, IPancakeRouterV2} from "./DeployV22GuardDemo.s.sol";

/// @title EPK guard demo on EPKVault 2.2.0 — allowed trades, sessions, attacks, ThreatFeed (BSC Testnet)
/// @notice Allowed trades are broadcast here. Attacks are only PREPARED (signed by the compromised operator /
///         agent / admin key) and written to JSON; `scripts/v2/demo_attacks.py` sends them with a fixed gas limit
///         so each rejection is mined on-chain.
///   forge script scripts/v2/RunV22GuardDemo.s.sol:RunV22GuardDemo --sig "allowed()"        --rpc-url $BSC_RPC_URL --broadcast --slow
///   forge script scripts/v2/RunV22GuardDemo.s.sol:RunV22GuardDemo --sig "prepareAttacks()" --rpc-url $BSC_RPC_URL
///   python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2.2-guards-attacks.json
///   forge script scripts/v2/RunV22GuardDemo.s.sol:RunV22GuardDemo --sig "control()"        --rpc-url $BSC_RPC_URL --broadcast
///   forge script scripts/v2/RunV22GuardDemo.s.sol:RunV22GuardDemo --sig "blockSupplier()"  --rpc-url $BSC_RPC_URL --broadcast
///   forge script scripts/v2/RunV22GuardDemo.s.sol:RunV22GuardDemo --sig "prepareBlocked()" --rpc-url $BSC_RPC_URL
///   python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2.2-guards-blocked.json
contract RunV22GuardDemo is GuardDemoPool {
    string internal constant DEPLOY = "deployments/bsc-testnet/epk-v2.2-guards.json";
    string internal constant RUN = "deployments/bsc-testnet/epk-v2.2-guards-run.json";
    string internal constant ATTACKS = "deployments/bsc-testnet/epk-v2.2-guards-attacks.json";
    string internal constant BLOCKED = "deployments/bsc-testnet/epk-v2.2-guards-blocked.json";
    address internal constant CAKE = 0xFa60D973F7642B748046464e165A65B7323b0DEE; // real testnet token, not listed
    uint256 internal constant TRADE_BNB = 0.0001 ether;
    uint256 internal constant TRADE_TUSD = 0.05 ether;

    EPKVault vault;
    DexGuard dex;
    IPancakeRouterV2 router;
    address wbnb;
    address busd;
    address tusd;
    uint256 pid;
    uint256 opPk;
    uint256 agentPk;

    function _testnetOnly() internal view {
        require(block.chainid == 97, "BSC Testnet only");
    }

    function _load() internal {
        string memory j = vm.readFile(DEPLOY);
        vault = EPKVault(payable(vm.parseJsonAddress(j, ".vault")));
        dex = DexGuard(vm.parseJsonAddress(j, ".dexGuard"));
        router = IPancakeRouterV2(vm.parseJsonAddress(j, ".router"));
        wbnb = vm.parseJsonAddress(j, ".wbnb");
        busd = vm.parseJsonAddress(j, ".busd");
        tusd = vm.parseJsonAddress(j, ".tusd");
        pid = vm.parseJsonUint(j, ".policy");
        opPk = vm.envUint("V21_OPERATOR_PRIVATE_KEY");
        agentPk = vm.envUint("V21_AGENT_PRIVATE_KEY");
    }

    function _quote(address a, address b, uint256 amountIn) internal view returns (uint256) {
        return router.getAmountsOut(amountIn, _pair2(a, b))[1];
    }

    function _one(address target, uint256 value, bytes memory data) internal pure returns (EPKVault.Call[] memory c) {
        c = new EPKVault.Call[](1);
        c[0] = EPKVault.Call(target, value, data);
    }

    function _bnbIn(uint256 minOut, address tokenOut, address to, uint256 swapDeadline)
        internal
        view
        returns (EPKVault.Call[] memory)
    {
        return _one(
            address(router),
            TRADE_BNB,
            abi.encodeCall(IPancakeRouterV2.swapExactETHForTokens, (minOut, _pair2(wbnb, tokenOut), to, swapDeadline))
        );
    }

    /// calldata of vault.execute(...) signed by `pk` for policy / session `id` with the current nonce
    function _signedExecute(uint256 id, uint256 pk, EPKVault.Call[] memory calls) internal view returns (bytes memory) {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 d = vault.getExecuteDigest(id, vm.addr(pk), calls, vault.nonces(id), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, d);
        return abi.encodeCall(EPKVault.execute, (id, calls, deadline, abi.encodePacked(r, s, v), ""));
    }

    function _send(uint256 id, uint256 pk, EPKVault.Call[] memory calls) internal {
        bytes memory data = _signedExecute(id, pk, calls);
        vm.startBroadcast(pk);
        (bool ok, bytes memory ret) = address(vault).call(data);
        vm.stopBroadcast();
        require(ok, string(ret));
    }

    // ------------------------------------------------------------------ allowed

    function allowed() external {
        _testnetOnly();
        _load();
        // prices move: first put the demo pool back at the Chainlink price
        uint256 adminPk = vm.envUint("V21_ADMIN_PRIVATE_KEY");
        vm.startBroadcast(adminPk);
        _alignPool(vm.addr(adminPk));
        vm.stopBroadcast();

        address supplier = vm.addr(vm.envUint("V21_SUPPLIER_PRIVATE_KEY"));
        address agent = vm.addr(agentPk);

        // S1 operator policy: 0.0001 BNB -> tUSD at the pool price (guard: fair value minus 1 %)
        uint256 out1 = _quote(wbnb, tusd, TRADE_BNB) * 999 / 1000;
        _send(pid, opPk, _bnbIn(out1, tusd, address(vault), block.timestamp + 300));

        // S2 operator policy: 0.05 tUSD -> BNB (approve, swap, reset the allowance)
        uint256 out2 = _quote(tusd, wbnb, TRADE_TUSD) * 999 / 1000;
        EPKVault.Call[] memory c = new EPKVault.Call[](3);
        c[0] = EPKVault.Call(tusd, 0, abi.encodeCall(IERC20.approve, (address(router), TRADE_TUSD)));
        c[1] = EPKVault.Call(
            address(router),
            0,
            abi.encodeCall(
                IPancakeRouterV2.swapExactTokensForETH,
                (TRADE_TUSD, out2, _pair2(tusd, wbnb), address(vault), block.timestamp + 300)
            )
        );
        c[2] = EPKVault.Call(tusd, 0, abi.encodeCall(IERC20.approve, (address(router), 0)));
        _send(pid, opPk, c);

        // S3 operator policy: pay a supplier 1 tUSD (a plain payment passes the guards)
        _send(pid, opPk, _one(tusd, 0, abi.encodeCall(IERC20.transfer, (supplier, 1e18))));

        // S4 the session manager opens two AI-agent sessions: one in the guarded envelope, one not
        vm.startBroadcast(vm.envUint("V21_SESSION_MANAGER_PRIVATE_KEY"));
        uint256 sidG = vault.openSession(1, agent, agent, uint48(block.timestamp + 1 days));
        uint256 sidU = vault.openSession(2, agent, agent, uint48(block.timestamp + 1 days));
        vm.stopBroadcast();

        // S5 the AI agent trades on its own inside the guarded session
        uint256 out5 = _quote(wbnb, tusd, TRADE_BNB) * 999 / 1000;
        _send(sidG, agentPk, _bnbIn(out5, tusd, address(vault), block.timestamp + 300));

        string memory o = "run";
        vm.serializeUint(o, "sessionGuarded", sidG);
        string memory out = vm.serializeUint(o, "sessionUnguarded", sidU);
        vm.writeJson(out, RUN);
        console2.log("vault tUSD:", IERC20(tusd).balanceOf(address(vault)));
        console2.log("vault BNB :", address(vault).balance);
    }

    // ------------------------------------------------------------------ attacks (prepared, not sent)

    function prepareAttacks() external {
        _testnetOnly();
        _load();
        string memory r = vm.readFile(RUN);
        uint256 sidG = vm.parseJsonUint(r, ".sessionGuarded");
        uint256 sidU = vm.parseJsonUint(r, ".sessionUnguarded");
        address attacker = vm.addr(vm.envUint("V21_ATTACKER_PRIVATE_KEY"));
        address supplier = vm.addr(vm.envUint("V21_SUPPLIER_PRIVATE_KEY"));
        uint256 dl = block.timestamp + 540; // inside the guard's 10-minute window: send right away
        uint256 fair = _quote(wbnb, tusd, TRADE_BNB);

        string memory o = "attacks";
        vm.serializeAddress(o, "vault", address(vault));
        vm.serializeString(o, "a_recipientAttacker_from", "operator");
        vm.serializeBytes(o, "a_recipientAttacker", _signedExecute(pid, opPk, _bnbIn(fair, tusd, attacker, dl)));
        vm.serializeString(o, "b_minOutOne_from", "operator");
        vm.serializeBytes(o, "b_minOutOne", _signedExecute(pid, opPk, _bnbIn(1, tusd, address(vault), dl)));
        // the real WBNB/BUSD pool, at its own quote — what a bot trusting the pool would accept
        vm.serializeString(o, "c_mispricedRealPool_from", "operator");
        vm.serializeBytes(
            o, "c_mispricedRealPool", _signedExecute(pid, opPk, _bnbIn(_quote(wbnb, busd, TRADE_BNB), busd, address(vault), dl))
        );
        vm.serializeString(o, "d_feeOnTransferFunction_from", "operator");
        vm.serializeBytes(
            o,
            "d_feeOnTransferFunction",
            _signedExecute(
                pid,
                opPk,
                _one(
                    address(router),
                    TRADE_BNB,
                    abi.encodeCall(
                        IPancakeRouterV2.swapExactETHForTokensSupportingFeeOnTransferTokens,
                        (fair, _pair2(wbnb, tusd), address(vault), dl)
                    )
                )
            )
        );
        vm.serializeString(o, "e_farDeadline_from", "operator");
        vm.serializeBytes(
            o, "e_farDeadline", _signedExecute(pid, opPk, _bnbIn(fair, tusd, address(vault), block.timestamp + 2 days))
        );
        vm.serializeString(o, "f_approveNonRouter_from", "operator");
        vm.serializeBytes(
            o, "f_approveNonRouter", _signedExecute(pid, opPk, _one(tusd, 0, abi.encodeCall(IERC20.approve, (supplier, 1e18))))
        );
        vm.serializeString(o, "g_unlistedToken_from", "operator");
        vm.serializeBytes(o, "g_unlistedToken", _signedExecute(pid, opPk, _bnbIn(1, CAKE, address(vault), dl)));
        vm.serializeString(o, "h_sessionToAttacker_from", "guardAgent");
        vm.serializeBytes(o, "h_sessionToAttacker", _signedExecute(sidG, agentPk, _bnbIn(fair, tusd, attacker, dl)));
        vm.serializeString(o, "i_unguardedSessionSwap_from", "guardAgent");
        vm.serializeBytes(
            o, "i_unguardedSessionSwap", _signedExecute(sidU, agentPk, _bnbIn(fair * 999 / 1000, tusd, address(vault), dl))
        );
        vm.serializeString(o, "j_removeGuardWithoutTimelock_from", "guardAdmin");
        vm.serializeBytes(o, "j_removeGuardWithoutTimelock", abi.encodeCall(EPKVault.setEnvelopeGuard, (1, address(0))));
        // fifth review A5-2: tokens parked at a router (an allowed destination) can be swept by anyone
        vm.serializeString(o, "l_transferToRouter_from", "operator");
        string memory out = vm.serializeBytes(
            o,
            "l_transferToRouter",
            _signedExecute(pid, opPk, _one(tusd, 0, abi.encodeCall(IERC20.transfer, (address(router), 1e18))))
        );
        vm.writeJson(out, ATTACKS);
        console2.log("prepared 11 attacks; swap deadline (unix):", dl);
    }

    // ------------------------------------------------------------------ control: a plain wallet, same trade

    function control() external {
        _testnetOnly();
        _load();
        address op = vm.addr(opPk);
        uint256 before = IERC20(busd).balanceOf(op);
        vm.startBroadcast(opPk);
        router.swapExactETHForTokens{value: TRADE_BNB}(0, _pair2(wbnb, busd), op, block.timestamp + 300);
        vm.stopBroadcast();
        uint256 got = IERC20(busd).balanceOf(op) - before;
        uint256 fair = dex.minimumOut(wbnb, busd, TRADE_BNB) * 10_000 / 9_900;
        console2.log("plain wallet received BUSD:", got);
        console2.log("fair value in BUSD        :", fair);
        console2.log("kept (bps of fair)        :", got * 10_000 / fair);
    }

    // ------------------------------------------------------------------ threat feed

    function blockSupplier() external {
        _testnetOnly();
        string memory j = vm.readFile(DEPLOY);
        ThreatFeedGuard feed = ThreatFeedGuard(vm.parseJsonAddress(j, ".threatFeed"));
        address[] memory a = new address[](1);
        a[0] = vm.parseJsonAddress(j, ".supplier");
        vm.startBroadcast(vm.envUint("V21_RESPONDER_PRIVATE_KEY"));
        feed.blockAddresses(a, "supplier reported as a drainer");
        vm.stopBroadcast();
    }

    function prepareBlocked() external {
        _testnetOnly();
        _load();
        address supplier = vm.addr(vm.envUint("V21_SUPPLIER_PRIVATE_KEY"));
        string memory o = "blocked";
        vm.serializeAddress(o, "vault", address(vault));
        vm.serializeString(o, "k_payBlockedSupplier_from", "operator");
        string memory out = vm.serializeBytes(
            o, "k_payBlockedSupplier", _signedExecute(pid, opPk, _one(tusd, 0, abi.encodeCall(IERC20.transfer, (supplier, 1e18))))
        );
        vm.writeJson(out, BLOCKED);
    }
}
