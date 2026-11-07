# EPK 2.1 guard demo — BSC Testnet

Goal: show on a real chain that **DexGuard**, **ThreatFeed V2** and **CompositeGuard** protect a vault's
trades — for an ordinary trading policy and for autonomous AI-agent sessions — using the **real
PancakeSwap V2 router** and **real Chainlink price feeds** on BSC Testnet (chainId 97).

Status: **done on 2026-11-07**, on a **separate** EPKVault 2.1.0 with its own registry, factory and keys.
The 2.0.x demo vault (`docs/TESTNET_V2.md`, 9,940 eUSD) and its 2.0.1 upgrade on 14–16 November are not
touched. Testnet only, test funds only, **not audited**. Source code of every contract we deployed is
verified on [Sourcify](https://sourcify.dev) (chain 97).

What this proves: the listed attacks were rejected on-chain in these scenarios, and allowed trades went
through at fair prices. It is **not** a guarantee that no other attack exists — see
[`GUARDS_v2.md`](GUARDS_v2.md) §2 for what the guards do not cover.

## Setup

- **Guard of the trading policy and of session envelope 1:** CompositeGuard = ThreatFeed V2 (checked first)
  + DexGuard (PancakeSwap V2 router only; tokens WBNB, BUSD, tUSD; 1 % slippage against Chainlink;
  swaps expire within 10 minutes; at most 0.001 BNB / 10 tokens per trade).
- **Prices:** BNB and BUSD from the real Chainlink BNB/USD and BUSD/USD feeds. tUSD is the demo's own
  test stablecoin with a fixed $1 test feed, and a small tUSD/WBNB pool seeded at the Chainlink price.
- **Session envelope 2** has the same calls but no guard — to show that an agent cannot use it to reach
  the router.
- **Roles** (separate testnet keys, local `.env`, never committed): admin, two guardians, recovery,
  session manager, operator (signs and submits the trading policy's batches), AI agent, ThreatFeed
  responder, a supplier (payee) and an attacker address that must never receive anything.

## Contracts

| Contract | Address |
|---|---|
| EPKVault 2.1.0 implementation | [0xE3F4897CB9dC4b7FE980f81eFC997CDB9AE93Fa4](https://testnet.bscscan.com/address/0xE3F4897CB9dC4b7FE980f81eFC997CDB9AE93Fa4) |
| EPKRegistry (2.1 demo, separate from the 2.0 demo) | [0x24E861F67180be06A65eF95874404D13FA9631F3](https://testnet.bscscan.com/address/0x24E861F67180be06A65eF95874404D13FA9631F3) |
| EPKVaultFactory (2.1 demo) | [0x38E841A9d917f8c7488A535Cf89c0F683D177027](https://testnet.bscscan.com/address/0x38E841A9d917f8c7488A535Cf89c0F683D177027) |
| EPKVault 2.1.0 demo vault (proxy) | [0x83c6D86019BfF5ebBb7bd955aa63878DAa60f674](https://testnet.bscscan.com/address/0x83c6D86019BfF5ebBb7bd955aa63878DAa60f674) |
| DexGuard | [0x5A00736dE12a925E7A9427dB7253C3074f434209](https://testnet.bscscan.com/address/0x5A00736dE12a925E7A9427dB7253C3074f434209) |
| ThreatFeed V2 (ThreatFeedGuard) | [0x327274073da2dCac166F20E68e2e7fD2fA15EDba](https://testnet.bscscan.com/address/0x327274073da2dCac166F20E68e2e7fD2fA15EDba) |
| CompositeGuard (ThreatFeed V2 + DexGuard) | [0x83e0a92F04EFE126D6Ce4aE6066FcEc5Ca849B09](https://testnet.bscscan.com/address/0x83e0a92F04EFE126D6Ce4aE6066FcEc5Ca849B09) |
| tUSD — the demo's test stablecoin | [0xc58699856ED5c978F7bf47e46650Bdb23d9bB119](https://testnet.bscscan.com/address/0xc58699856ED5c978F7bf47e46650Bdb23d9bB119) |
| fixed $1 test feed for tUSD | [0xD246D8d4d58d7b444159Bd8cFf9B6fb00f27105C](https://testnet.bscscan.com/address/0xD246D8d4d58d7b444159Bd8cFf9B6fb00f27105C) |
| PancakeSwap V2 router (BSC Testnet, not ours) | [0xD99D1c33F9fC3444f8101754aBC46c52416550D1](https://testnet.bscscan.com/address/0xD99D1c33F9fC3444f8101754aBC46c52416550D1) |
| PancakeSwap tUSD/WBNB pool seeded at the Chainlink price | [0x6d370d9654daafda5d0bb89080e1d7b7c2f80c9e](https://testnet.bscscan.com/address/0x6d370d9654daafda5d0bb89080e1d7b7c2f80c9e) |
| BUSD (BSC Testnet, not ours) | [0x78867BbEeF44f2326bF8DDd1941a4439382EF2A7](https://testnet.bscscan.com/address/0x78867BbEeF44f2326bF8DDd1941a4439382EF2A7) |
| PancakeSwap WBNB/BUSD pool (BSC Testnet, not ours) | [0x85ecdcdd01ebe0bfd0aba74b81ca6d7f4a53582b](https://testnet.bscscan.com/address/0x85ecdcdd01ebe0bfd0aba74b81ca6d7f4a53582b) |
| Chainlink BNB / USD (BSC Testnet) | [0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526](https://testnet.bscscan.com/address/0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526) |
| Chainlink BUSD / USD (BSC Testnet) | [0x9331b55D9830EF609A2aBCfAc0FBCE050A52fdEa](https://testnet.bscscan.com/address/0x9331b55D9830EF609A2aBCfAc0FBCE050A52fdEa) |

## What happened

| # | What | Transaction | Result |
|---|---|---|---|
| D2 | admin seeds a tUSD/WBNB pool at the Chainlink BNB price (0.03 BNB) | [0x86b9c9dd…](https://testnet.bscscan.com/tx/0x86b9c9dd13cab057f29ddcdd76bf7930009f7a58bb3120c80768877b5d5549bf) | success |
| D1 | admin creates a separate EPKVault 2.1.0 through the 2.1 demo factory | [0x3e1218e1…](https://testnet.bscscan.com/tx/0x3e1218e193a902ddd59767ef6d7ea9aed98378d5d008989939e0191299b02fc1) | success |
| D3 | trading policy for the operator key, guarded by ThreatFeed V2 + DexGuard | [0x332a9395…](https://testnet.bscscan.com/tx/0x332a9395275e4264ae240ee085426b08e2f9553ceb584cd3551ccfeb923d25c3) | success |
| D4 | agent-session envelope 1 gets the same guard (envelope 2 stays unguarded on purpose) | [0x96070d72…](https://testnet.bscscan.com/tx/0x96070d729722689f45ab6a97ccbb91f4ed1a87e9f5bd21d1c7dbf3eebcd6850b) | success |
| D5 | setup finished: from now on every loosening needs the 1-hour timelock | [0x8c410890…](https://testnet.bscscan.com/tx/0x8c410890b809a3acb2b43ad7d0bdd76a8fd43c867f5eedf2675bc396ef0f3c75) | success |
| S1 | operator: vault swaps 0.0001 BNB for tUSD on PancakeSwap — at a fair price, output to the vault | [0xe0955e69…](https://testnet.bscscan.com/tx/0xe0955e69559dfe8bbec781ec66c50dac629fcbc2b3d5ce997d14efa5642d6154) | success |
| S2 | operator: vault sells 0.05 tUSD for BNB (approve, swap, allowance reset) | [0x9f8f213e…](https://testnet.bscscan.com/tx/0x9f8f213eecd6c3c7089dc4d6ff1d93e7b8bb81826472e954f5a2d4bd1733b1e1) | success |
| S3 | operator: vault pays the supplier 1 tUSD (plain payments pass the guards) | [0xf7cdbdf8…](https://testnet.bscscan.com/tx/0xf7cdbdf8dba2111ea6ac3f354ccb3f05caa2b0964fee883a4841c1fff2edbe0a) | success |
| S4 | session manager opens an AI-agent session in the GUARDED envelope 1 | [0x07ba4365…](https://testnet.bscscan.com/tx/0x07ba43655ce5d8810351426d3f3cdda2aaeca82ea160ba8e4a7060f30929e3de) | success |
| S5 | session manager opens an AI-agent session in the UNGUARDED envelope 2 | [0x56d1a197…](https://testnet.bscscan.com/tx/0x56d1a197b3e978d6b123f4052ad88c0262937d03eb219fab7ef18fde647839cf) | success |
| S6 | AI agent, on its own, swaps 0.0001 BNB for tUSD inside the guarded session | [0x30f6077c…](https://testnet.bscscan.com/tx/0x30f6077cd5d7f8fc8dc5a8d1bdfa8c3877cada9ee721c83e4a0930d0e9875573) | success |
| A1 | operator key signs a swap whose output goes to the attacker | [0x230bea92…](https://testnet.bscscan.com/tx/0x230bea921b660091505a4f448c743f603065d99f09d0a4e5f96f3b3c78832616) | **rejected**: `RecipientNotVault` |
| A2 | operator key signs a swap that accepts any price (minimum out = 1) | [0x5220be5d…](https://testnet.bscscan.com/tx/0x5220be5d551033fcf40020f9e85fa6815d86c165b8b26d583b7edf3d87c464d8) | **rejected**: `PriceTooLow` |
| A3 | operator key signs a swap on the REAL WBNB/BUSD pool at that pool's own quote (~38 % below Chainlink) | [0x9db601b5…](https://testnet.bscscan.com/tx/0x9db601b5833b4284d3cd7b85f2d51d97f2bb34c613ff2d5da2ab8e34d18daabb) | **rejected**: `PriceTooLow` |
| A4 | operator key uses an unsupported router function (fee-on-transfer variant) | [0x05853bd3…](https://testnet.bscscan.com/tx/0x05853bd3bc7e3e8a9b339becb2b50584a748e0f22134846ea669f5762453e999) | **rejected**: `UnsupportedCall` |
| A5 | operator key signs a swap valid for 2 days (to run later at a worse price) | [0x35c4ad27…](https://testnet.bscscan.com/tx/0x35c4ad2706ed7c7483facf9f8e46110c5fc3ceda9ab87f99f5db896b660b67f9) | **rejected**: `BadDeadline` |
| A6 | operator key approves a non-router (the supplier) to pull tUSD | [0x95737ee1…](https://testnet.bscscan.com/tx/0x95737ee150630e8d602acc7c20e8b537e0dbd80917e73825c91c344a5507fbaa) | **rejected**: `ApproveToNonRouter` |
| A7 | operator key swaps into a token that is not on the guard's list (CAKE) | [0x928d90b0…](https://testnet.bscscan.com/tx/0x928d90b08b8d3dcbdb59755e6626f282227064e460b7d1560fe9557099a449bf) | **rejected**: `TokenNotAllowed` |
| A8 | AI agent (guarded session) sends a swap's output to the attacker | [0xa0d40d9e…](https://testnet.bscscan.com/tx/0xa0d40d9efa4edc3b0ba50944e3e6327ffddf79e7b60c698eae493e56549fe855) | **rejected**: `RecipientNotVault` |
| A9 | AI agent uses the UNGUARDED session to call the router — the other path | [0x2df4abbb…](https://testnet.bscscan.com/tx/0x2df4abbb15f84e31fa624d5ea7e2831ba04403fa8227e61c5bd458a8fba1bfd1) | **rejected**: `GuardRequired` |
| A10 | admin key tries to remove the session guard without the timelock | [0xcd45ca08…](https://testnet.bscscan.com/tx/0xcd45ca08b953f4de349748649f9e32572c17e9a770834ca4553e435ffa094cd6) | **rejected**: `NotTimelocked` |
| C1 | control: a PLAIN wallet (no EPK) makes the same 0.0001 BNB -> BUSD trade on the real pool | [0x633484ff…](https://testnet.bscscan.com/tx/0x633484ff7490a921c407e5c24ffbd71552e31f9ad5f250b60c4339a8e88c8d04) | success |
| A11 | ThreatFeed V2: a responder blocks the supplier (reported as a drainer) — instantly | [0x347505f7…](https://testnet.bscscan.com/tx/0x347505f7a206ece05527dbad2885b59c7ed3ddd54e94f6670e21a953c840c036) | success |
| A12 | after the block: operator key tries to pay the supplier again | [0xdcdb871c…](https://testnet.bscscan.com/tx/0xdcdb871c562434e53d1ca36cb57f21d55fcbea17c28ae4a6741aa875e35b0cd6) | **rejected**: `BlockedAddress` |

**The headline result (A3 vs C1):** the real WBNB/BUSD pool on BSC Testnet pays about **38 % less**
than the Chainlink price. A plain wallet that trusts the pool's own quote made that trade and received
0.0431 BUSD for 0.0001 BNB instead of about 0.0696 (C1). The EPK vault, asked to make the same trade by a
compromised operator key, refused it on-chain with `PriceTooLow` (A3).

During all attacks not a single tUSD left the vault, and the attacker address received nothing.

## Check it yourself

```bash
python scripts/v2/verify_evidence.py --evidence deployments/bsc-testnet/epk-v2.1-evidence.json --doc docs/TESTNET_V21.md
```

Python 3 only — no Foundry, no keys. It checks the chain id, every contract's code hash (and, with
`--build` after `forge build`, that it equals this repository's build), that the 2.1.0 implementation is
pinned in the demo registry and that the vault proxy points to it, every transaction's sender and
target, the events and exact amounts of the successful steps, and the revert reason of every attack —
**STRICT** from execution traces saved in `deployments/bsc-testnet/traces/` right after sending, or by
replay. Free public nodes keep historical state only for about 2 hours, so the report of the day is
archived in `deployments/bsc-testnet/verification/`.

## How it was run

```bash
forge script scripts/v2/DeployV21Demo.s.sol:DeployV21Demo --rpc-url $BSC_RPC_URL --broadcast --slow
forge script scripts/v2/RunV21Demo.s.sol:RunV21Demo --sig "allowed()" --rpc-url $BSC_RPC_URL --broadcast --slow
forge script scripts/v2/RunV21Demo.s.sol:RunV21Demo --sig "prepareAttacks()" --rpc-url $BSC_RPC_URL
python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2.1-attacks.json
forge script scripts/v2/RunV21Demo.s.sol:RunV21Demo --sig "control()" --rpc-url $BSC_RPC_URL --broadcast
forge script scripts/v2/RunV21Demo.s.sol:RunV21Demo --sig "blockSupplier()" --rpc-url $BSC_RPC_URL --broadcast
forge script scripts/v2/RunV21Demo.s.sol:RunV21Demo --sig "prepareBlocked()" --rpc-url $BSC_RPC_URL
python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2.1-blocked.json
python scripts/v2/build_v21_evidence.py
```
