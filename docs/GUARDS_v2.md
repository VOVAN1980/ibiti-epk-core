# EPK guards — protected swaps for trading bots and AI agents

Status (2026-11-08): **built and tested** (preview), and **running on BSC Testnet on a separate demo vault on
release 2.2.0**: allowed trades and 12 attacks through the real PancakeSwap V2 router with real Chainlink
feeds, every claim re-checkable — [`TESTNET_V22_GUARDS.md`](TESTNET_V22_GUARDS.md), live check in the
browser: `docs/proof/guards.html`. Not audited, not on mainnet. The EPK v2 demo vault keeps running 2.0.x,
untouched.

| Module | File | What it does |
|---|---|---|
| **DexGuard** | `contracts/v2/guards/DexGuard.sol` | Only verified routers, functions and tokens; output to the vault only; Chainlink fair price with a slippage limit; short deadlines; per-trade cap; checks what actually arrived |
| **ThreatFeed V2** | `contracts/v2/guards/ThreatFeedGuard.sol` | Shared blocklist: instant blocking, delayed unblocking that responders can veto |
| **CompositeGuard** | `contracts/v2/guards/CompositeGuard.sol` | Several guards in one slot (all must pass) |
| **Vault 2.1.0** | `contracts/v2/EPKVault.sol` | Guards for agent sessions; unguarded sessions cannot call routers; after-batch check hook |

Guards sit outside the vault. They can only **reject**: they hold no permissions and never move funds.
The vault keeps every limit it already had — per-asset outflow limits, session budgets, the
destination allowlist, the timelock, `panic()`.

## 1. Attacks it stops

Each line is a test that sends the attack through a real `EPKVault` 2.1.0 and expects the rejection
(`test/v2/guards/`).

| # | Attack (signed by a compromised operator key or AI agent) | Rejected with | Test |
|---|---|---|---|
| 1 | Swap the vault's tokens and send the output to the attacker | `RecipientNotVault` | `test_attack_swapOutputToAttacker` |
| 2 | Sell at any price (minimum out = 1): sandwich, manipulated pool | `PriceTooLow` | `test_attack_noSlippageProtection` |
| 3 | Overpay on an exact-output swap | `PriceTooHigh` | `test_attack_overpayExactOutput` |
| 4 | Route through a worthless or attacker-made token | `TokenNotAllowed` | `test_attack_junkTokenInPath` |
| 5 | Hide a swap inside the router's `multicall` | `UnsupportedCall` | `test_attack_multicallBypass` |
| 6 | Use an unsupported router function (fee-on-transfer variants, liquidity, …) | `UnsupportedCall` | `test_attack_unsupportedRouterFunction` |
| 7 | Approve a non-router to pull the vault's tokens | `ApproveToNonRouter` | `test_attack_approveNonRouter` |
| 8 | Sign a swap now, hold it back, run it later | `BadDeadline` | `test_attack_farDeadline` |
| 9 | One oversized trade | `AmountTooLarge` | `test_attack_tooLargeTrade` |
| 10 | Trade on a stale, broken or out-of-bounds price | `StalePrice` / `BadPrice` | `test_attack_staleOrBrokenPrice` |
| 11 | Router or token delivers less than promised (e.g. a transfer tax switched on) | `BalanceCheckFailed` (after the batch) | `test_attack_routerDeliversLess` |
| 12 | AI agent takes another path: a session without a guard calls a router | `GuardRequired` (vault) | `test_session_withoutGuardCannotSwap` |
| 13 | Add, swap or remove a session guard without notice (e.g. a stolen admin key installing a guard that lets everything through) | `NotTimelocked` — every change waits in the timelock; guardians / Watchtower can cancel | `test_session_guardChangesAreTimelocked` |
| 14 | Trade through a token or pay an address that turned out to be malicious | `BlockedAddress` (ThreatFeed) | `test_blockedTokenStopsSwaps`, `test_blockedRecipientStopsPayments` |
| 15 | V3 single-pool swap with a price limit: the router stops early, charges the maximum and delivers dust (found in the 2026-11-08 audit) | `PriceLimitNotAllowed` | `test_v3PriceLimitPartialFillIsRefused` |
| 16 | Hide a short swap by wrapping the vault's own BNB into the output token in the same batch | `BalanceCheckFailed` (wraps are booked) | `test_wrapCannotHideAShortSwap` |
| 17 | Send tokens straight to a router (an allowlisted destination) and sweep them out (`sweepToken`, `removeLiquidity…SupportingFeeOnTransferTokens`) | `RecipientNotAllowed` | `test_transferToRouterIsRefused`, `test_transferFromToRouterIsRefused` |

The vault's own limits still bound everything a guard allows (`test_vaultLimitsStillApply`,
`test_session_budgetStillApplies`).

**On a fork of the real BSC Testnet** (real PancakeSwap V2 router, real Chainlink feeds,
`test/v2/guards/DexGuard.fork.t.sol`, log in `deployments/bsc-testnet/v2.1/`): the live WBNB/BUSD pool
paid **38 % less** than the Chainlink price. A bot that trusts the pool's own quote loses that; the
guarded vault refused the trade, while a fairly priced pool worked in both directions through the same
router.

**Under random attack** (`DexGuard.invariant.t.sol`, 3 × 256 runs × 500 calls): a compromised operator
signs random swaps — to the attacker, with any minimum, through manipulated pools and routers that
deliver less — while prices move. The attacker never receives anything, no allowance survives a
batch, and every swap that went through returned at least the fair value minus the allowed slippage
(worst observed: 99.06 % of fair value with a 1 % limit).

## 2. What it does not cover

Stated openly, so integrators can plan around it:

- **MEV inside the allowed slippage.** Each trade can still lose up to `maxSlippageBps` of its value.
- **The oracle itself.** The guard trusts the configured Chainlink feeds within their staleness limit and
  price bounds. A wrong feed inside those bounds is not detected.
- **Unsupported trading venues are refused, not inspected:** Universal Router command streams,
  SwapRouter02-style routers without a deadline, aggregators, V3 swaps paying native coin. Fee-on-transfer
  and rebasing tokens are not supported.
- **Swapping and sending the swapped token in one batch** fails the after-batch check (it counts the net
  change). Do them in separate batches.
- **Vaults on 2.0.x**: no after-batch check, and sessions cannot use guards — never give router calls to a
  2.0.x session envelope (the timelock and the Watchtower stand in front of that change).
- **Ordinary policies without a guard** can call whatever the admin allowlisted through the timelock.
  Always give a trading policy a guard.
- **ThreatFeed alone** checks the call target and every word-aligned address argument; token addresses
  packed inside a V3 path, and addresses inside a nested call's bytes (multicall payloads), are not seen.
  DexGuard refuses multicalls and lists every path token — use both together. A token that gets blocked
  can still be bought through a V3 path until the DexGuard is replaced through the timelock.
- **ThreatFeed as the only envelope guard** lifts `GuardRequired`: sessions may then make every allowlisted
  call uninspected. Put it in a CompositeGuard together with DexGuard.
- **The feed owner** can remove blockers at once, so a stolen owner key can open a blocked address after
  `unblockDelay`. Keep the owner key cold (a multisig).
- **Validators written for 2.0 (`validate` only)**: a 2.1.0 vault also calls `afterBatch` on a policy's
  validator, so such a validator makes every batch revert. Wrap it in a CompositeGuard with `legacy = true`.
- **The DexGuard deployed for the testnet demo** (`0x5A00…4209`) predates the 2026-11-08 fixes (rows 15–17):
  deploy a fresh guard (`deployDexGuard` in the SDK) for any new setup.
- **Immutable configuration**: a mistake in a guard's settings means deploying a new guard and switching
  to it through the timelock.
- Not audited yet.

## 3. How a developer connects it

### 3.1 Deploy a guard

```solidity
DexGuard.RouterInit[] memory routers = new DexGuard.RouterInit[](1);
routers[0] = DexGuard.RouterInit(PANCAKE_V2_ROUTER, DexGuard.RouterKind.V2);

DexGuard.TokenInit[] memory tokens = new DexGuard.TokenInit[](2);
//                       token  Chainlink feed  max age  max per trade  price sanity bounds (feed decimals)
tokens[0] = DexGuard.TokenInit(WBNB, BNB_USD_FEED, 1 hours, 50e18,       1e8,  100_000e8);
tokens[1] = DexGuard.TokenInit(USDT, USDT_USD_FEED, 1 days, 50_000e18,   0.9e8, 1.1e8);

DexGuard guard = new DexGuard(
    WBNB,        // wrapped native token (prices native-coin swaps), or address(0) to refuse them
    100,         // max slippage: 1 % (at most 10 %)
    10 minutes,  // longest swap deadline allowed
    routers,
    tokens
);
```

Optional: a shared `ThreatFeedGuard(owner, unblockDelay)` and a `CompositeGuard([dexGuard, feed], [false, false])`
to run both.

### 3.2 Give the guard to a policy or a session envelope

During setup the admin does this directly; after `finalizeSetup()` it goes through `schedule(...)` →
delay → `executeScheduled(...)` (guardians and the Watchtower can cancel).

```solidity
vault.addDestination(PANCAKE_V2_ROUTER);                 // the router may receive approvals / native coin
vault.setAsset(USDT, maxPerDay, 1 days, coSignAbove);    // every traded token is tracked and limited

// an ordinary trading policy
uint256 pid = vault.createPolicy(botSigner, 0, maxNativePerCall, address(guard));
vault.setCall(pid, PANCAKE_V2_ROUTER, IRouter.swapExactTokensForTokens.selector, true);
vault.setCall(pid, USDT, IERC20.approve.selector, true);

// or: AI-agent sessions (vault 2.1.0)
vault.setEnvelope(envId, true, maxTtl, maxNativePerCall);
vault.setEnvelopeCall(envId, PANCAKE_V2_ROUTER, IRouter.swapExactTokensForTokens.selector, true);
vault.setEnvelopeBudgetCap(envId, USDT, perSessionBudget);
vault.setEnvelopeGuard(envId, address(guard));           // every guard change is timelocked after setup
```

### 3.3 What the bot signs

```solidity
uint256 minOut = guard.minimumOut(USDT, WBNB, amountIn);   // exactly the rule the guard will enforce
Call[] memory calls = new Call[](3);
calls[0] = Call(USDT, 0, abi.encodeCall(IERC20.approve, (ROUTER, amountIn)));
calls[1] = Call(ROUTER, 0, abi.encodeCall(IRouter.swapExactTokensForTokens,
                 (amountIn, minOut, path, address(vault), block.timestamp + 5 minutes)));
calls[2] = Call(USDT, 0, abi.encodeCall(IERC20.approve, (ROUTER, 0)));   // no allowance may survive
bytes32 digest = vault.getExecuteDigest(policyId, agent, calls, vault.nonces(policyId), deadline);
// sign `digest` with the policy / session key, then the agent calls vault.execute(...)
```

`guard.maximumIn(tokenIn, tokenOut, amountOut)` gives the limit for exact-output swaps. Errors a bot
should handle: `PriceTooLow`, `PriceTooHigh`, `StalePrice`, `BadPrice`, `BadDeadline`, `AmountTooLarge`,
`TokenNotAllowed`, `UnsupportedCall`, `BalanceCheckFailed`, and from the vault `LimitExceeded`,
`BudgetExceeded`, `GuardRequired`. SDK v2 wraps all of this: `DexGuardClient`, `planGuardedSwap`, `explainEpkError`.

### 3.4 Supported router functions

| Router type | Functions |
|---|---|
| V2 (PancakeSwap / Uniswap V2) | `swapExactTokensForTokens`, `swapTokensForExactTokens`, `swapExactETHForTokens`, `swapETHForExactTokens`, `swapExactTokensForETH`, `swapTokensForExactETH` (paths of 2–4 tokens) |
| V3 (`SwapRouter` with a deadline) | `exactInputSingle`, `exactInput`, `exactOutputSingle`, `exactOutput` (up to 3 hops, no native coin) |

## 4. Run the tests

```bash
forge test --match-path "test/v2/guards/*"
BSC_TESTNET_FORK_RPC=https://bsc-testnet-rpc.publicnode.com forge test --match-path "test/v2/guards/DexGuard.fork.t.sol" -vv
```
