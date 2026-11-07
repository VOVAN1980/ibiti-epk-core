// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EPKVault} from "../../contracts/v2/EPKVault.sol";

/// @title Step 3 — an AI agent works inside its session (BSC testnet)
/// @notice The session manager opens a 3-day session for the agent; the agent (its own key signs and
///         submits) pays 50 eUSD to the owner's treasury. Then the script PREPARES — without sending —
///         five attack transactions and writes them to deployments/bsc-testnet/epk-v2-attacks.json;
///         scripts/v2/demo_attacks.py sends them so each one is rejected on-chain.
/// forge script scripts/v2/DemoSession.s.sol:DemoSession --rpc-url $BSC_RPC_URL --broadcast
contract DemoSession is Script {
    string internal constant IN_CORE = "deployments/bsc-testnet/epk-v2.json";
    string internal constant IN_VAULT = "deployments/bsc-testnet/epk-v2-vault.json";
    string internal constant OUT = "deployments/bsc-testnet/epk-v2-attacks.json";

    EPKVault internal vault;
    address internal token;
    address internal treasury;
    uint256 internal agentPk;
    address internal agent;

    function run() external {
        string memory core = vm.readFile(IN_CORE);
        string memory v = vm.readFile(IN_VAULT);
        vault = EPKVault(payable(vm.parseJsonAddress(v, ".vault")));
        token = vm.parseJsonAddress(core, ".token");
        treasury = vm.parseJsonAddress(v, ".admin");
        uint256 envelope = vm.parseJsonUint(v, ".envelope");
        uint256 managerPk = vm.envUint("V2_SESSION_MANAGER_PRIVATE_KEY");
        agentPk = vm.envUint("V2_AGENT_PRIVATE_KEY");
        agent = vm.addr(agentPk);

        // 1) session manager opens a session for the agent (instant, inside the envelope)
        vm.broadcast(managerPk);
        uint256 sid = vault.openSession(envelope, agent, agent, uint48(block.timestamp + 3 days));

        // 2) the agent pays 50 eUSD to the treasury — signed and submitted by the agent alone
        EPKVault.Call[] memory pay = _transfer(treasury, 50e18);
        uint256 deadline = block.timestamp + 2 hours;
        bytes memory sig = _sign(agentPk, sid, agent, pay, vault.nonces(sid), deadline);
        vm.broadcast(agentPk);
        vault.execute(sid, pay, deadline, sig, "");

        console2.log("Session id:", sid);
        console2.log("Session budget left (eUSD):", vault.budgetAvailable(sid, token) / 1e18);
        console2.log("Vault limit left today (eUSD):", vault.availableToSpend(token) / 1e18);

        // 3) prepare attacks (not sent here): all use the session's next nonce
        _prepareAttacks(sid, deadline);
    }

    function _prepareAttacks(uint256 sid, uint256 deadline) internal {
        uint256 nonce = vault.nonces(sid);
        uint256 strangerPk = vm.envUint("V2_GUARDIAN2_PRIVATE_KEY"); // any key that is not the agent

        string memory o = "attacks";
        vm.serializeUint(o, "sessionId", sid);

        // a) spend over the session budget (100/day, 50 already spent)
        EPKVault.Call[] memory c = _transfer(treasury, 60e18);
        _store(o, "a_overBudget", _exec(sid, c, deadline, _sign(agentPk, sid, agent, c, nonce, deadline)), "agent");

        // b) send to an address that is not allowlisted
        c = _transfer(0x000000000000000000000000000000000000dEaD, 1e18);
        _store(o, "b_unknownDestination", _exec(sid, c, deadline, _sign(agentPk, sid, agent, c, nonce, deadline)), "agent");

        // c) a call the envelope does not allow (approve)
        c = _one(token, abi.encodeCall(IERC20.approve, (treasury, 1e18)));
        _store(o, "c_callNotAllowed", _exec(sid, c, deadline, _sign(agentPk, sid, agent, c, nonce, deadline)), "agent");

        // d) a forged signature (signed by a key that is not the session key)
        c = _transfer(treasury, 1e18);
        _store(o, "d_forgedSignature", _exec(sid, c, deadline, _sign(strangerPk, sid, agent, c, nonce, deadline)), "agent");

        // e) a stranger submits a valid signature that belongs to the agent
        string memory json = vm.serializeBytes(
            o, "e_notTheAgent", _exec(sid, c, deadline, _sign(agentPk, sid, agent, c, nonce, deadline))
        );
        json = vm.serializeString(o, "e_notTheAgent_from", "guardian2");
        vm.writeJson(json, OUT);
        console2.log("Prepared 5 attack transactions:", OUT);
    }

    function _store(string memory o, string memory key, bytes memory data, string memory from) internal {
        vm.serializeBytes(o, key, data);
        vm.serializeString(o, string.concat(key, "_from"), from);
    }

    function _exec(uint256 sid, EPKVault.Call[] memory calls, uint256 deadline, bytes memory sig)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(EPKVault.execute, (sid, calls, deadline, sig, ""));
    }

    function _transfer(address to, uint256 amount) internal view returns (EPKVault.Call[] memory) {
        return _one(token, abi.encodeCall(IERC20.transfer, (to, amount)));
    }

    function _one(address target, bytes memory data) internal pure returns (EPKVault.Call[] memory c) {
        c = new EPKVault.Call[](1);
        c[0] = EPKVault.Call(target, 0, data);
    }

    function _sign(
        uint256 pk,
        uint256 sid,
        address agent_,
        EPKVault.Call[] memory calls,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = vault.getExecuteDigest(sid, agent_, calls, nonce, deadline);
        (uint8 v_, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v_);
    }
}
