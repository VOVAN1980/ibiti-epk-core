// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EPKVault} from "../../contracts/v2/EPKVault.sol";

/// @title Step 4 — panic and recovery (BSC testnet)
/// Phase 1 (now):        forge script scripts/v2/DemoPanic.s.sol:DemoPanic --sig "panicAndScheduleUnpause()" --rpc-url $BSC_RPC_URL --broadcast
/// Phase 2 (after delay): forge script scripts/v2/DemoPanic.s.sol:DemoPanic --sig "recover()" --rpc-url $BSC_RPC_URL --broadcast
/// Phase 2 also prepares deployments/bsc-testnet/epk-v2-after-panic.json: the old session trying to pay
/// again (must be rejected: panic ended it for good) — send it with scripts/v2/demo_attacks.py.
contract DemoPanic is Script {
    string internal constant IN_CORE = "deployments/bsc-testnet/epk-v2.json";
    string internal constant IN_VAULT = "deployments/bsc-testnet/epk-v2-vault.json";
    string internal constant IN_ATTACKS = "deployments/bsc-testnet/epk-v2-attacks.json";
    string internal constant OUT = "deployments/bsc-testnet/epk-v2-after-panic.json";
    bytes32 internal constant SALT = keccak256("EPK demo: unpause after panic");

    EPKVault internal vault;
    address internal token;
    address internal treasury;

    function _load() internal {
        vault = EPKVault(payable(vm.parseJsonAddress(vm.readFile(IN_VAULT), ".vault")));
        token = vm.parseJsonAddress(vm.readFile(IN_CORE), ".token");
        treasury = vm.parseJsonAddress(vm.readFile(IN_VAULT), ".admin");
    }

    function panicAndScheduleUnpause() external {
        require(block.chainid == 97 || block.chainid == 11155111 || block.chainid == 31337, "EPK: test networks only");
        _load();
        vm.broadcast(vm.envUint("V2_GUARDIAN1_PRIVATE_KEY"));
        vault.panic(); // a guardian stops everything instantly
        vm.broadcast(vm.envUint("PRIVATE_KEY"));
        vault.schedule(abi.encodeCall(EPKVault.unpause, ()), SALT); // unpausing goes through the timelock
        console2.log("Paused:", vault.paused());
        console2.log("Unpause can be executed after (unix time):", block.timestamp + vault.delay());
    }

    function recover() external {
        require(block.chainid == 97 || block.chainid == 11155111 || block.chainid == 31337, "EPK: test networks only");
        _load();
        uint256 agentPk = vm.envUint("V2_AGENT_PRIVATE_KEY");
        address agent = vm.addr(agentPk);
        uint256 oldSid = vm.parseJsonUint(vm.readFile(IN_ATTACKS), ".sessionId");

        vm.broadcast(vm.envUint("PRIVATE_KEY"));
        vault.executeScheduled(abi.encodeCall(EPKVault.unpause, ()), SALT);

        // a new session works again
        vm.broadcast(vm.envUint("V2_SESSION_MANAGER_PRIVATE_KEY"));
        uint256 sid = vault.openSession(1, agent, agent, uint48(block.timestamp + 3 days));
        EPKVault.Call[] memory pay = _transfer(treasury, 10e18);
        uint256 deadline = block.timestamp + 2 hours;
        bytes memory sig = _sign(agentPk, sid, agent, pay, vault.nonces(sid), deadline);
        vm.broadcast(agentPk);
        vault.execute(sid, pay, deadline, sig, "");
        console2.log("New session after recovery:", sid);

        // the old session is dead for good: prepare its payment attempt (to be rejected on-chain)
        bytes memory oldSig = _sign(agentPk, oldSid, agent, pay, vault.nonces(oldSid), deadline);
        string memory o = "afterPanic";
        vm.serializeUint(o, "newSessionId", sid);
        vm.serializeBytes(o, "f_oldSessionAfterPanic", abi.encodeCall(EPKVault.execute, (oldSid, pay, deadline, oldSig, "")));
        string memory json = vm.serializeString(o, "f_oldSessionAfterPanic_from", "agent");
        vm.writeJson(json, OUT);
    }

    function _transfer(address to, uint256 amount) internal view returns (EPKVault.Call[] memory c) {
        c = new EPKVault.Call[](1);
        c[0] = EPKVault.Call(token, 0, abi.encodeCall(IERC20.transfer, (to, amount)));
    }

    function _sign(uint256 pk, uint256 sid, address agent, EPKVault.Call[] memory calls, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v_, bytes32 r, bytes32 s) = vm.sign(pk, vault.getExecuteDigest(sid, agent, calls, nonce, deadline));
        return abi.encodePacked(r, s, v_);
    }
}
