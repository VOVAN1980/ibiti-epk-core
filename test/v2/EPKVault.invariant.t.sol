// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {EPKVault} from "../../contracts/v2/EPKVault.sol";
import {EPKVaultFactory} from "../../contracts/v2/EPKVaultFactory.sol";
import {TestToken, MockRouter} from "./V2Mocks.sol";

/// The attacker controls the operator signer, the agent AND the co-signer, and tries random
/// sequences of actions over time. Admin and guardians are honest (they never act here).
contract CompromisedOperatorHandler is Test {
    EPKVault public vault;
    TestToken public token;
    MockRouter public router;
    address public agent;
    address public friend;
    address public attacker;
    uint256 internal signerPk;
    uint256 internal coSignerPk;
    uint256 internal pid;

    uint256 public attempts;
    uint256 public successes;

    constructor(
        EPKVault vault_,
        TestToken token_,
        MockRouter router_,
        address agent_,
        address friend_,
        address attacker_,
        uint256 signerPk_,
        uint256 coSignerPk_,
        uint256 pid_
    ) {
        vault = vault_;
        token = token_;
        router = router_;
        agent = agent_;
        friend = friend_;
        attacker = attacker_;
        signerPk = signerPk_;
        coSignerPk = coSignerPk_;
        pid = pid_;
    }

    function _run(EPKVault.Call[] memory calls) internal {
        attempts++;
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 d = vault.getExecuteDigest(pid, agent, calls, vault.nonces(pid), deadline);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(signerPk, d);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(coSignerPk, vault.getCoSignDigest(d));
        vm.prank(agent);
        try vault.execute(pid, calls, deadline, abi.encodePacked(r1, s1, v1), abi.encodePacked(r2, s2, v2)) {
            successes++;
        } catch {}
    }

    function _one(address target, uint256 value, bytes memory data) internal pure returns (EPKVault.Call[] memory c) {
        c = new EPKVault.Call[](1);
        c[0] = EPKVault.Call(target, value, data);
    }

    function transferToken(uint256 amount, bool toAttacker) external {
        amount = bound(amount, 0, 300e18);
        _run(_one(address(token), 0, abi.encodeCall(IERC20.transfer, (toAttacker ? attacker : friend, amount))));
    }

    function sendNative(uint256 amount, bool toAttacker) external {
        amount = bound(amount, 0, 3 ether);
        _run(_one(toAttacker ? attacker : friend, amount, ""));
    }

    /// Tries to leave an allowance behind (the H-1 attack).
    function approveAndLeave(uint256 amount, bool toAttacker) external {
        amount = bound(amount, 1, 1_000e18);
        address spender = toAttacker ? attacker : address(router);
        _run(_one(address(token), 0, abi.encodeCall(IERC20.approve, (spender, amount))));
    }

    /// Legit swap-like batch through an allowlisted router: approve -> pull -> approve(0).
    function swapLike(uint256 amount, uint256 pulled) external {
        amount = bound(amount, 1, 300e18);
        pulled = bound(pulled, 0, amount);
        EPKVault.Call[] memory calls = new EPKVault.Call[](3);
        calls[0] = EPKVault.Call(address(token), 0, abi.encodeCall(IERC20.approve, (address(router), amount)));
        calls[1] = EPKVault.Call(
            address(router), 0, abi.encodeCall(MockRouter.pull, (address(token), address(vault), friend, pulled))
        );
        calls[2] = EPKVault.Call(address(token), 0, abi.encodeCall(IERC20.approve, (address(router), 0)));
        _run(calls);
    }

    function wait(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 0, 12 hours));
    }
}

contract EPKVaultInvariantTest is Test {
    EPKVaultFactory factory;
    EPKVault vault;
    TestToken token;
    MockRouter router;
    CompromisedOperatorHandler handler;

    address admin = makeAddr("admin");
    address agent = makeAddr("agent");
    address friend = makeAddr("friend");
    address attacker = makeAddr("attacker");

    uint128 constant TOKEN_CAP = 100e18;
    uint128 constant NATIVE_CAP = 1 ether;
    uint32 constant WINDOW = 1 days;

    uint256 start;
    uint256 tokenStart;
    uint256 nativeStart;

    function setUp() public {
        factory = new EPKVaultFactory();
        token = new TestToken("TKN");
        router = new MockRouter();

        address[] memory g = new address[](2);
        g[0] = makeAddr("guardian1");
        g[1] = makeAddr("guardian2");
        vm.prank(admin);
        vault = EPKVault(payable(factory.createVault(g, 1 days, address(0), bytes32("inv"))));

        uint256 signerPk = 0x51;
        uint256 coSignerPk = 0xC0;
        vm.startPrank(admin);
        vault.setAsset(address(token), TOKEN_CAP, WINDOW, 50e18);
        vault.setAsset(vault.NATIVE(), NATIVE_CAP, WINDOW, type(uint128).max);
        vault.addDestination(friend);
        vault.addDestination(address(router));
        uint256 pid = vault.createPolicy(vm.addr(signerPk), 0, 2 ether, address(0));
        vault.setAgent(pid, agent, true, 0);
        vault.setCall(pid, address(token), IERC20.transfer.selector, true);
        vault.setCall(pid, address(token), IERC20.approve.selector, true);
        vault.setCall(pid, address(router), MockRouter.pull.selector, true);
        vault.setCall(pid, friend, bytes4(0), true);
        vault.setCall(pid, attacker, bytes4(0), true);
        vault.setCoSigner(vm.addr(coSignerPk));
        vault.finalizeSetup();
        vm.stopPrank();

        token.mint(address(vault), 10_000e18);
        vm.deal(address(vault), 100 ether);

        handler =
            new CompromisedOperatorHandler(vault, token, router, agent, friend, attacker, signerPk, coSignerPk, pid);
        targetContract(address(handler));

        start = vm.getBlockTimestamp();
        tokenStart = token.balanceOf(address(vault));
        nativeStart = address(vault).balance;
    }

    /// The attacker must actually manage to act, otherwise the invariants would hold trivially.
    function afterInvariant() external view {
        assertGt(handler.successes(), 0, "no successful executions in this run");
    }

    function _bound(uint256 cap) internal view returns (uint256) {
        return cap + cap * (vm.getBlockTimestamp() - start) / WINDOW;
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_outflowNeverExceedsTheLimit() public view {
        assertLe(tokenStart - token.balanceOf(address(vault)), _bound(TOKEN_CAP), "token outflow over limit");
        assertLe(nativeStart - address(vault).balance, _bound(NATIVE_CAP), "native outflow over limit");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_noAllowanceSurvives() public view {
        assertEq(token.allowance(address(vault), address(router)), 0);
        assertEq(token.allowance(address(vault), attacker), 0);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_attackerGetsNothing() public view {
        assertEq(token.balanceOf(attacker), 0);
        assertEq(attacker.balance, 0);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_onlyAllowlistedDestinationsReceive() public view {
        assertEq(
            tokenStart - token.balanceOf(address(vault)),
            token.balanceOf(friend) + token.balanceOf(address(router)),
            "tokens went somewhere unexpected"
        );
    }
}
