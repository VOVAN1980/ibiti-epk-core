# EPK guard demo — BSC Testnet

Goal: show on a real chain that **DexGuard**, **ThreatFeed V2** and **CompositeGuard** protect a vault's
trades — for an ordinary trading policy and for autonomous AI-agent sessions — using the **real
PancakeSwap V2 router** and **real Chainlink price feeds** on BSC Testnet (chainId 97).

Status: **done on 2026-11-08** (21:51–21:57 UTC), on an EPKVault **2.3.0** created through the **public 2.3.0
factory** — the same way any integrator's vault is created (SDK `networks.bscTestnet.epk.factory`). Its
registry and vault run the clocks of public test networks (`contracts/v2/EPKChains.sol`): a new release is
usable after a 5-minute public window, a vault upgrades 5 minutes after scheduling, and the vault's own
timelock for loosening its settings is 5 minutes. Production rules (7-day window, at least 2 days per upgrade,
a timelock of at least 1 hour) apply on every other chain. The guards are deployed from this repository's
code. Testnet only, test funds only, **not audited**. The main demo vault ([`TESTNET_V2.md`](TESTNET_V2.md))
is a separate vault.

What this proves: the listed attacks were rejected on-chain in these scenarios, and allowed trades went
through at fair prices. It is **not** a guarantee that no other attack exists — see
[`GUARDS_v2.md`](GUARDS_v2.md) §2 for what the guards do not cover. Step **A11** shows a fix of the fifth
internal review (A5-2, [SECURITY_REVIEW_v2.md §1e](SECURITY_REVIEW_v2.md)): tokens sent to a router — an
allowed destination — could be swept by anyone, so DexGuard refuses any token transfer to a router.

## Setup

- **Guard of the trading policy and of session envelope 1:** CompositeGuard = ThreatFeed V2 (checked first)
  + DexGuard (PancakeSwap V2 router only; tokens WBNB, BUSD, tUSD; 1 % slippage against Chainlink;
  swaps expire within 10 minutes; at most 0.001 BNB / 10 tokens per trade).
- **Prices:** BNB and BUSD from the real Chainlink BNB/USD and BUSD/USD feeds. tUSD is the demo's own test
  stablecoin with a fixed $1 test feed, and a small tUSD/WBNB pool on the real router. Only the demo admin
  can mint tUSD, so only the admin can move that pool's price: before setup and before trading the scripts
  check it against Chainlink and correct it if it is more than 0.1 % away. This time it was already at the
  price both times, so nothing had to be sold into it.
- **Session envelope 2** has the same calls but no guard — to show that an agent cannot use it to reach
  the router.
- **Roles** (separate testnet keys, local `.env`, never committed): admin, two guardians, recovery, session
  manager, operator (signs and submits the trading policy's batches), AI agent, ThreatFeed responder, a
  supplier (payee) and an attacker address that must never receive anything.

## Contracts

| Contract | Address |
|---|---|
| EPKVault 2.3.0 implementation (the current public release) | [0x214c7a5a9B6b25d559ac714050B66A09E050eA32](https://testnet.bscscan.com/address/0x214c7a5a9B6b25d559ac714050B66A09E050eA32) |
| EPKRegistry of the public stack (5-minute test-network release window) | [0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db](https://testnet.bscscan.com/address/0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db) |
| EPKVaultFactory for 2.3.0 — the SDK's public factory | [0xbBCeFb781E1A9A21593C4E22a28B6AA2C2bc817B](https://testnet.bscscan.com/address/0xbBCeFb781E1A9A21593C4E22a28B6AA2C2bc817B) |
| EPKVault 2.3.0 guard demo vault (proxy) | [0x3Bdd9c884B168bbFa41C181328548a5e42180FD3](https://testnet.bscscan.com/address/0x3Bdd9c884B168bbFa41C181328548a5e42180FD3) |
| DexGuard (with the 2026-11-08 fixes) | [0x1FC77bbe5947687e4094b0cD8842b6C7d4485C31](https://testnet.bscscan.com/address/0x1FC77bbe5947687e4094b0cD8842b6C7d4485C31) |
| ThreatFeed V2 (ThreatFeedGuard) | [0xC30d44F5c87c91d8a5EF3942546Ee478abD40815](https://testnet.bscscan.com/address/0xC30d44F5c87c91d8a5EF3942546Ee478abD40815) |
| CompositeGuard (ThreatFeed V2 + DexGuard) | [0xc46373543fA89c36D6Eca1455A28C3FDbCCc3C0B](https://testnet.bscscan.com/address/0xc46373543fA89c36D6Eca1455A28C3FDbCCc3C0B) |
| tUSD — the guard demo's test stablecoin | [0xc58699856ED5c978F7bf47e46650Bdb23d9bB119](https://testnet.bscscan.com/address/0xc58699856ED5c978F7bf47e46650Bdb23d9bB119) |
| fixed $1 test feed for tUSD | [0xD246D8d4d58d7b444159Bd8cFf9B6fb00f27105C](https://testnet.bscscan.com/address/0xD246D8d4d58d7b444159Bd8cFf9B6fb00f27105C) |
| PancakeSwap V2 router (BSC Testnet, not ours) | [0xD99D1c33F9fC3444f8101754aBC46c52416550D1](https://testnet.bscscan.com/address/0xD99D1c33F9fC3444f8101754aBC46c52416550D1) |
| PancakeSwap tUSD/WBNB pool, kept at the Chainlink price by the demo admin | [0x6d370d9654daafda5d0bb89080e1d7b7c2f80c9e](https://testnet.bscscan.com/address/0x6d370d9654daafda5d0bb89080e1d7b7c2f80c9e) |
| BUSD (BSC Testnet, not ours) | [0x78867BbEeF44f2326bF8DDd1941a4439382EF2A7](https://testnet.bscscan.com/address/0x78867BbEeF44f2326bF8DDd1941a4439382EF2A7) |
| PancakeSwap WBNB/BUSD pool (BSC Testnet, not ours) | [0x85ecdcdd01ebe0bfd0aba74b81ca6d7f4a53582b](https://testnet.bscscan.com/address/0x85ecdcdd01ebe0bfd0aba74b81ca6d7f4a53582b) |
| Chainlink BNB / USD (BSC Testnet) | [0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526](https://testnet.bscscan.com/address/0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526) |
| Chainlink BUSD / USD (BSC Testnet) | [0x9331b55D9830EF609A2aBCfAc0FBCE050A52fdEa](https://testnet.bscscan.com/address/0x9331b55D9830EF609A2aBCfAc0FBCE050A52fdEa) |

## What happened

| # | What | Transaction | Result |
|---|---|---|---|
| D2 | admin creates a new EPKVault 2.3.0 through the PUBLIC 2.3.0 factory (5-minute test-network upgrade clocks) | [0xa75969b2…](https://testnet.bscscan.com/tx/0xa75969b2d6ae450a92d6f034697a8a7b8405bac692129336f38442c024bd2eee) | success |
| D3 | trading policy for the operator key, guarded by ThreatFeed V2 + DexGuard | [0x4c843ec5…](https://testnet.bscscan.com/tx/0x4c843ec5960a71b921da1fa927c753f4a12e8cd8ac82284c981753a9414dd752) | success |
| D4 | agent-session envelope 1 gets the same guard (envelope 2 stays unguarded on purpose) | [0x474bdb1d…](https://testnet.bscscan.com/tx/0x474bdb1d907677c50d64de271ae3057ee43f1dcaf438105e7dd0a6849541867d) | success |
| D5 | setup finished: from now on every loosening needs the 5-minute timelock | [0x1ec4145c…](https://testnet.bscscan.com/tx/0x1ec4145cd1364861e296b6198b1d364661909c1ded8666f178da89e6114c8f2b) | success |
| S1 | operator: vault swaps 0.0001 BNB for tUSD on PancakeSwap — at a fair price, output to the vault | [0x1527d86a…](https://testnet.bscscan.com/tx/0x1527d86a2dcd4e893739f7cb6d085ce71649bc79346cc61e2bd62c87561b86f0) | success |
| S2 | operator: vault sells 0.05 tUSD for BNB (approve, swap, allowance reset) | [0xfb083732…](https://testnet.bscscan.com/tx/0xfb0837323cc62b03eac47228dbde7381c817b245d55753f49330d4790035db18) | success |
| S3 | operator: vault pays the supplier 1 tUSD (plain payments pass the guards) | [0x75776f35…](https://testnet.bscscan.com/tx/0x75776f350511254df9e047d06a7540e117f2df90aa5e102480546cacbffa633c) | success |
| S4 | session manager opens an AI-agent session in the GUARDED envelope 1 | [0x419f94ec…](https://testnet.bscscan.com/tx/0x419f94ecd415ba8254e1a00325f00a804fae2c576f71e2fc4f68f6b1db47e519) | success |
| S5 | session manager opens an AI-agent session in the UNGUARDED envelope 2 | [0x6e9af42d…](https://testnet.bscscan.com/tx/0x6e9af42dd2f5b8e2d26b834700a0d646a825200c8bf60c1b4fb3d4c4eb3e63ea) | success |
| S6 | AI agent, on its own, swaps 0.0001 BNB for tUSD inside the guarded session | [0x22e29186…](https://testnet.bscscan.com/tx/0x22e29186b9c83b490c2b0d26a186487cf828cfabde1140e83f4a839eb3ef0cd0) | success |
| A1 | operator key signs a swap whose output goes to the attacker | [0x42ec5b4d…](https://testnet.bscscan.com/tx/0x42ec5b4de2735e1c04330b6c9c28aa34d74cee2a2c12e3e8031ab450a5053e23) | **rejected**: `RecipientNotVault` |
| A2 | operator key signs a swap that accepts any price (minimum out = 1) | [0x50cbd2b2…](https://testnet.bscscan.com/tx/0x50cbd2b2e197692e41b8cfb402054a677486433a568a62ce22bd53040fc9c161) | **rejected**: `PriceTooLow` |
| A3 | operator key signs a swap on the REAL WBNB/BUSD pool at that pool's own quote (~37 % below Chainlink) | [0x2588f599…](https://testnet.bscscan.com/tx/0x2588f5993219594651b72899be1c7b4f2fc9b6edfb5c0dedee6e6ecbd62eb40f) | **rejected**: `PriceTooLow` |
| A4 | operator key uses an unsupported router function (fee-on-transfer variant) | [0x5d76ae6d…](https://testnet.bscscan.com/tx/0x5d76ae6d627afba3e0689f37ba60ae79219db0ef33b5ff228681b14c5bc225a9) | **rejected**: `UnsupportedCall` |
| A5 | operator key signs a swap valid for 2 days (to run later at a worse price) | [0x09593e8d…](https://testnet.bscscan.com/tx/0x09593e8da443bf8943f0c08d8b95e63924378825e1fbb2d78085dd3cd5588c93) | **rejected**: `BadDeadline` |
| A6 | operator key approves a non-router (the supplier) to pull tUSD | [0xa0012be5…](https://testnet.bscscan.com/tx/0xa0012be506b84a49f2030ce601303ac79fa086b30ef9ee38fedf77abf9f5b3e7) | **rejected**: `ApproveToNonRouter` |
| A7 | operator key swaps into a token that is not on the guard's list (CAKE) | [0x5fb4626c…](https://testnet.bscscan.com/tx/0x5fb4626c086a03e3557f5f01c1cd4261e9134785df2f422e38cbb30047074d5f) | **rejected**: `TokenNotAllowed` |
| A8 | AI agent (guarded session) sends a swap's output to the attacker | [0x44fc5eb9…](https://testnet.bscscan.com/tx/0x44fc5eb9b3b311e2a6ebd1e6374dc215ac25438a02847737f1a279751e10a49d) | **rejected**: `RecipientNotVault` |
| A9 | AI agent uses the UNGUARDED session to call the router — the other path | [0x1ece4ab4…](https://testnet.bscscan.com/tx/0x1ece4ab4873d6a79d3ded40471b35e21bc61b1a65a3ae253aec64db1209801d4) | **rejected**: `GuardRequired` |
| A10 | admin key tries to remove the session guard without the timelock | [0x7fbafb3c…](https://testnet.bscscan.com/tx/0x7fbafb3cea45261b2bdb1e495972c89d58571eb08ae3c3d0a170afa65a373b11) | **rejected**: `NotTimelocked` |
| A11 | operator key parks 1 tUSD at the router, where anyone could sweep it | [0xfca148d7…](https://testnet.bscscan.com/tx/0xfca148d7be662e732f85e4009daae4a2a549c641cab70db6bfb762ca182d8d98) | **rejected**: `RecipientNotAllowed` |
| C1 | control: a PLAIN wallet (no EPK) makes the same 0.0001 BNB -> BUSD trade on the real pool | [0xc4aecc5b…](https://testnet.bscscan.com/tx/0xc4aecc5b77eede91860c75c5dd4c224d7fea8aa67f079a4931c3cedea113dd83) | success |
| A12 | ThreatFeed V2: a responder blocks the supplier (reported as a drainer) — instantly | [0x667951e8…](https://testnet.bscscan.com/tx/0x667951e85fa01dd7a2720ab1d8f9ff44828a5880a4b0175323b8bde515470f30) | success |
| A13 | after the block: operator key tries to pay the supplier again | [0x7df9d850…](https://testnet.bscscan.com/tx/0x7df9d850634c92981cf73ff1a46ce065dd7e266e668def74f58a19924f819a53) | **rejected**: `BlockedAddress` |

**The headline result (A3 vs C1):** the real WBNB/BUSD pool on BSC Testnet pays about **37 % less** than the
Chainlink price. A plain wallet that trusts the pool's own quote made that trade and received 0.0431 BUSD for
0.0001 BNB instead of about 0.0681 (C1). The EPK vault, asked to make the same trade by a compromised operator
key, refused it on-chain with `PriceTooLow` (A3). On the fair pool the vault's own trade (S1) received
0.0688 tUSD for 0.0001 BNB — 99.5 % of the Chainlink value.

During all attacks not a single tUSD left the vault, and the attacker address received nothing.

## Check it yourself

```bash
python scripts/v2/verify_evidence.py --evidence deployments/bsc-testnet/epk-guards-evidence.json --doc docs/TESTNET_GUARDS.md
```

Python 3 only — no Foundry, no keys. It checks the chain id, every contract's code hash (and, with
`--build` after `git checkout 223e56f && forge build` — the source these contracts were built from —, that the vault implementation, the factory, the vault proxy and the three
guards equal this repository's build), that the implementation is pinned in the registry and that the vault
proxy points to it, every transaction's sender and target, the events and exact amounts of the successful
steps, and the revert reason of every attack — **STRICT** from the execution traces saved in
`deployments/bsc-testnet/traces/` right after sending. The script asks several free public nodes in turn
(see "How long history lasts" in [TESTNET_V2.md](TESTNET_V2.md)); what no node asked can answer is reported
as OLD, never as passed.

Last run 2026-11-08 with the default nodes: **113 checks OK, 0 mismatches, 0 OLD** — all 12 attack reasons
STRICT, no tUSD left the vault (`deployments/bsc-testnet/verification/2026-11-08T2158Z-guards-report.txt` and the
raw node answers `2026-11-08T2158Z-guards-rpc-snapshot.json`). With `--build`: **119 checks OK** — the vault
implementation, the factory, the vault proxy and the three guards equal this repository's build byte for byte
(`2026-11-08T2159Z-guards-build-report.txt`).

## How it was run

```bash
forge script scripts/v2/DeployGuardDemo.s.sol:DeployGuardDemo --rpc-url $BSC_RPC_URL --broadcast --slow
forge script scripts/v2/RunGuardDemo.s.sol:RunGuardDemo --sig "allowed()" --rpc-url $BSC_RPC_URL --broadcast --slow
forge script scripts/v2/RunGuardDemo.s.sol:RunGuardDemo --sig "prepareAttacks()" --rpc-url $BSC_RPC_URL
python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-guards-attacks.json
forge script scripts/v2/RunGuardDemo.s.sol:RunGuardDemo --sig "control()" --rpc-url $BSC_RPC_URL --broadcast
forge script scripts/v2/RunGuardDemo.s.sol:RunGuardDemo --sig "blockSupplier()" --rpc-url $BSC_RPC_URL --broadcast
forge script scripts/v2/RunGuardDemo.s.sol:RunGuardDemo --sig "prepareBlocked()" --rpc-url $BSC_RPC_URL
python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-guards-blocked.json
python scripts/v2/build_guards_evidence.py
```
