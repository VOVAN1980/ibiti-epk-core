// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RunV21Demo} from "./RunV21Demo.s.sol";
import {GuardDemoPool} from "./DeployV22GuardDemo.s.sol";

/// @title EPK guard demo on EPKVault 2.2.0 — allowed trades, sessions, attacks, ThreatFeed (BSC Testnet)
/// @notice The same steps as the 2.1 guard demo (`RunV21Demo`), on the 2.2.0 demo vault's files, plus one
///         attack the 2.1 demo's guard let through (fifth review A5-2, fixed 2026-11-08): the operator key
///         parks the vault's tUSD at the router, where anyone could sweep it.
///   forge script scripts/v2/RunV22GuardDemo.s.sol:RunV22GuardDemo --sig "allowed()"        --rpc-url $BSC_RPC_URL --broadcast --slow
///   forge script scripts/v2/RunV22GuardDemo.s.sol:RunV22GuardDemo --sig "prepareAttacks()" --rpc-url $BSC_RPC_URL
///   python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2.2-guards-attacks.json
///   forge script scripts/v2/RunV22GuardDemo.s.sol:RunV22GuardDemo --sig "control()"        --rpc-url $BSC_RPC_URL --broadcast
///   forge script scripts/v2/RunV22GuardDemo.s.sol:RunV22GuardDemo --sig "blockSupplier()"  --rpc-url $BSC_RPC_URL --broadcast
///   forge script scripts/v2/RunV22GuardDemo.s.sol:RunV22GuardDemo --sig "prepareBlocked()" --rpc-url $BSC_RPC_URL
///   python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2.2-guards-blocked.json
contract RunV22GuardDemo is GuardDemoPool, RunV21Demo {
    function DEPLOY() internal pure override returns (string memory) {
        return "deployments/bsc-testnet/epk-v2.2-guards.json";
    }

    function RUN() internal pure override returns (string memory) {
        return "deployments/bsc-testnet/epk-v2.2-guards-run.json";
    }

    function ATTACKS() internal pure override returns (string memory) {
        return "deployments/bsc-testnet/epk-v2.2-guards-attacks.json";
    }

    function BLOCKED() internal pure override returns (string memory) {
        return "deployments/bsc-testnet/epk-v2.2-guards-blocked.json";
    }

    /// @notice Prices move: put the demo pool back at the Chainlink price, then the 2.1 demo's allowed trades.
    function allowed() public override {
        require(block.chainid == 97, "BSC Testnet only");
        uint256 adminPk = vm.envUint("V21_ADMIN_PRIVATE_KEY");
        vm.startBroadcast(adminPk);
        _alignPool(vm.addr(adminPk));
        vm.stopBroadcast();
        super.allowed();
    }

    function _moreAttacks(string memory o, string memory) internal override returns (string memory) {
        vm.serializeString(o, "l_transferToRouter_from", "operator");
        return vm.serializeBytes(
            o,
            "l_transferToRouter",
            _signedExecute(pid, opPk, _one(tusd, 0, abi.encodeCall(IERC20.transfer, (address(router), 1e18))))
        );
    }
}
