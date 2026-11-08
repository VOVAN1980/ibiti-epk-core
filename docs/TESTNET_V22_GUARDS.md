# EPK guard demo — BSC Testnet

Goal: show on a real chain that **DexGuard**, **ThreatFeed V2** and **CompositeGuard** protect a vault's
trades — for an ordinary trading policy and for autonomous AI-agent sessions — using the **real
PancakeSwap V2 router** and **real Chainlink price feeds** on BSC Testnet (chainId 97).

Status: **done on 2026-11-08** (15:58–16:05 UTC), on an EPKVault **2.2.0** created through the **public 2.2.0
factory** — the same way any integrator's vault is created (SDK `networks.bscTestnet.epk.factory`). Its
registry and vault run the clocks of public test networks (`contracts/v2/EPKChains.sol`): a new release is
usable after a 5-minute public window and a vault upgrades 5 minutes after scheduling. Production rules
(7-day window, at least 2 days per upgrade) apply on every other chain. The vault's own timelock for
loosening its settings is 1 hour (the minimum on every network). The guards are deployed from this
repository's code. Testnet only, test funds only, **not audited**. The main demo vault
([`TESTNET_V2.md`](TESTNET_V2.md)) is a separate vault.

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
  can mint tUSD, so only the admin can move that pool's price: step D1 put it at the Chainlink price
  ($697.47) by selling 0.1166 freshly minted tUSD into it.
- **Session envelope 2** has the same calls but no guard — to show that an agent cannot use it to reach
  the router.
- **Roles** (separate testnet keys, local `.env`, never committed): admin, two guardians, recovery, session
  manager, operator (signs and submits the trading policy's batches), AI agent, ThreatFeed responder, a
  supplier (payee) and an attacker address that must never receive anything.

## Contracts

| Contract | Address |
|---|---|
| EPKVault 2.2.0 implementation (public release, 2026-11-08) | [0xD5cb4eB76cBABF55769f8c4ebfFb13754b1E5Ffd](https://testnet.bscscan.com/address/0xD5cb4eB76cBABF55769f8c4ebfFb13754b1E5Ffd) |
| EPKRegistry of the public 2.2.0 stack (5-minute test-network release window) | [0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db](https://testnet.bscscan.com/address/0xe6475FF06BDb17b828B8411Ca12F5a657daCD9db) |
| EPKVaultFactory for 2.2.0 — the SDK's public factory | [0xA128110b6C89E3A55E1F7815b75D48fcb124EB48](https://testnet.bscscan.com/address/0xA128110b6C89E3A55E1F7815b75D48fcb124EB48) |
| EPKVault 2.2.0 guard demo vault (proxy) | [0x5c2585f1f0725E54F8742798A20972Caa192eCba](https://testnet.bscscan.com/address/0x5c2585f1f0725E54F8742798A20972Caa192eCba) |
| DexGuard (with the 2026-11-08 fixes) | [0xE40E81fc52d54F20ff883C3177878A3ECc03e152](https://testnet.bscscan.com/address/0xE40E81fc52d54F20ff883C3177878A3ECc03e152) |
| ThreatFeed V2 (ThreatFeedGuard) | [0xAc4128402295c8e8e68b77b518B1ae823BFcB271](https://testnet.bscscan.com/address/0xAc4128402295c8e8e68b77b518B1ae823BFcB271) |
| CompositeGuard (ThreatFeed V2 + DexGuard) | [0xCc6a261A6FD502F9122Bf0CEAd4a03157988577D](https://testnet.bscscan.com/address/0xCc6a261A6FD502F9122Bf0CEAd4a03157988577D) |
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
| D1 | setup: admin puts the demo pool at the Chainlink BNB price (sells 0.11663690678691548 freshly minted tUSD into it) | [0x8bbf81f2…](https://testnet.bscscan.com/tx/0x8bbf81f23b5b4a196b90777245ed6228091d8d364e516686a1b25360b75b9cec) | success |
| D2 | admin creates a new EPKVault 2.2.0 through the PUBLIC 2.2.0 factory (5-minute test-network upgrade clocks) | [0x4c993749…](https://testnet.bscscan.com/tx/0x4c993749ba85851533890b6f8be72d0bd6f080118d1f929e103dec29817775f4) | success |
| D3 | trading policy for the operator key, guarded by ThreatFeed V2 + DexGuard | [0x7466a115…](https://testnet.bscscan.com/tx/0x7466a115a3aaf46cdd3d08a9f29720f091fdc4e202ac2702287cc908bcaef349) | success |
| D4 | agent-session envelope 1 gets the same guard (envelope 2 stays unguarded on purpose) | [0x2386e1d7…](https://testnet.bscscan.com/tx/0x2386e1d7fa856d9687d3f0f7d15a6dfb474616c501496215825bdda0b788c5b3) | success |
| D5 | setup finished: from now on every loosening needs the 1-hour timelock | [0xcb4d2d7f…](https://testnet.bscscan.com/tx/0xcb4d2d7f3bb51925088b22854519e8a8733083fb86dd9c3dde8074a6aa4a153e) | success |
| S1 | operator: vault swaps 0.0001 BNB for tUSD on PancakeSwap — at a fair price, output to the vault | [0xa9f625c4…](https://testnet.bscscan.com/tx/0xa9f625c4268e8e439d6cff3c1a317e876dc92d9f6d4fe174f8c8f3ee2c8fdc65) | success |
| S2 | operator: vault sells 0.05 tUSD for BNB (approve, swap, allowance reset) | [0x1a68e0f2…](https://testnet.bscscan.com/tx/0x1a68e0f225f38a17d96368c773b63ea98135b28bec8fcf3fbcd428647fc17404) | success |
| S3 | operator: vault pays the supplier 1 tUSD (plain payments pass the guards) | [0x2bbf0ad2…](https://testnet.bscscan.com/tx/0x2bbf0ad223ecded29e15a621996f667b370b52b327ef06e8ffb4af6db57611b1) | success |
| S4 | session manager opens an AI-agent session in the GUARDED envelope 1 | [0x3032e0b0…](https://testnet.bscscan.com/tx/0x3032e0b0ea5ff24358e0bac60a20d0acb814c967b80089657910c8d0c94f64cd) | success |
| S5 | session manager opens an AI-agent session in the UNGUARDED envelope 2 | [0x3b95e268…](https://testnet.bscscan.com/tx/0x3b95e26832453e17ebc7d245ed09f17ae20176fe63d7f1f8aa647e105cc20286) | success |
| S6 | AI agent, on its own, swaps 0.0001 BNB for tUSD inside the guarded session | [0x54a3b91f…](https://testnet.bscscan.com/tx/0x54a3b91f3bcc3a356331f5eb70a15f31c5d28623e9bff6a66af72313a62caf8b) | success |
| A1 | operator key signs a swap whose output goes to the attacker | [0x41cad69c…](https://testnet.bscscan.com/tx/0x41cad69c3f762b2da3a723548b6d0254bedb750db591d1be020e093e4cf40ede) | **rejected**: `RecipientNotVault` |
| A2 | operator key signs a swap that accepts any price (minimum out = 1) | [0x49b896ac…](https://testnet.bscscan.com/tx/0x49b896ac63b6d4ed57558eba1695401235071f75406e0fede2701b25ecc7b625) | **rejected**: `PriceTooLow` |
| A3 | operator key signs a swap on the REAL WBNB/BUSD pool at that pool's own quote (~38 % below Chainlink) | [0x39bce468…](https://testnet.bscscan.com/tx/0x39bce468392c0d40c8908c37d406fcb9434bc9176cefee3865734a940adfa595) | **rejected**: `PriceTooLow` |
| A4 | operator key uses an unsupported router function (fee-on-transfer variant) | [0x8eae5848…](https://testnet.bscscan.com/tx/0x8eae584826656c50d8b156fcf74f185da25106fe555c9a0c29811c8b7459464b) | **rejected**: `UnsupportedCall` |
| A5 | operator key signs a swap valid for 2 days (to run later at a worse price) | [0x31c1bcb5…](https://testnet.bscscan.com/tx/0x31c1bcb544ec447029741ec469a56470b0930ca7b785b7dbb2abbb6a014b2852) | **rejected**: `BadDeadline` |
| A6 | operator key approves a non-router (the supplier) to pull tUSD | [0xd2fb0b14…](https://testnet.bscscan.com/tx/0xd2fb0b14ea331c60ec6e55ab456053eb558ad3e0dd0845fad356e142c760cf44) | **rejected**: `ApproveToNonRouter` |
| A7 | operator key swaps into a token that is not on the guard's list (CAKE) | [0x566790e1…](https://testnet.bscscan.com/tx/0x566790e1a36d5d30037bde04a56da34f29aa8a74e34783268904f1fe4e5bd214) | **rejected**: `TokenNotAllowed` |
| A8 | AI agent (guarded session) sends a swap's output to the attacker | [0xabbca00f…](https://testnet.bscscan.com/tx/0xabbca00fdbcfb548aef4450b63504efc737f79eee8184de5802e7dcca549738f) | **rejected**: `RecipientNotVault` |
| A9 | AI agent uses the UNGUARDED session to call the router — the other path | [0x3b7b081a…](https://testnet.bscscan.com/tx/0x3b7b081aa823db8ef9c9251f2f7ac2f31efc43d92b3abb8ff3795b0ba594a164) | **rejected**: `GuardRequired` |
| A10 | admin key tries to remove the session guard without the timelock | [0x9922269c…](https://testnet.bscscan.com/tx/0x9922269c83f475f3356cd59fe6ccfd259fc9975b3d05c350519cf071510a84af) | **rejected**: `NotTimelocked` |
| A11 | operator key parks 1 tUSD at the router, where anyone could sweep it | [0x3214e7a7…](https://testnet.bscscan.com/tx/0x3214e7a7c881f70e28d0bc557c6c7cbab0797cac3af0f9d828dc053998918aa3) | **rejected**: `RecipientNotAllowed` |
| C1 | control: a PLAIN wallet (no EPK) makes the same 0.0001 BNB -> BUSD trade on the real pool | [0x5fe1a6ca…](https://testnet.bscscan.com/tx/0x5fe1a6ca1b105408bfc847ae443ee642b8e8bc76ec633ea332efd4bbca6f4fdf) | success |
| A12 | ThreatFeed V2: a responder blocks the supplier (reported as a drainer) — instantly | [0x8bc5f0bf…](https://testnet.bscscan.com/tx/0x8bc5f0bfa5de037945fb07301fec359ab0e180d02e9ff3c54863042c06db0aae) | success |
| A13 | after the block: operator key tries to pay the supplier again | [0x40c5a495…](https://testnet.bscscan.com/tx/0x40c5a4958de345c29409f7f918d7e3f86445b23c2c322791156fb2af53d6727d) | **rejected**: `BlockedAddress` |

**The headline result (A3 vs C1):** the real WBNB/BUSD pool on BSC Testnet pays about **38 % less** than the
Chainlink price. A plain wallet that trusts the pool's own quote made that trade and received 0.0431 BUSD for
0.0001 BNB instead of about 0.0698 (C1). The EPK vault, asked to make the same trade by a compromised operator
key, refused it on-chain with `PriceTooLow` (A3). On the fair pool the vault's own trade (S1) received
0.0694 tUSD for 0.0001 BNB — 99.5 % of the Chainlink value.

During all attacks not a single tUSD left the vault, and the attacker address received nothing.

## Check it yourself

```bash
python scripts/v2/verify_evidence.py --evidence deployments/bsc-testnet/epk-v2.2-guards-evidence.json --doc docs/TESTNET_V22_GUARDS.md
```

Python 3 only — no Foundry, no keys. It checks the chain id, every contract's code hash (and, with
`--build` after `git checkout dfe6d0e && forge build` — the code these contracts were deployed from —, that the vault implementation, the factory, the vault proxy and the three
guards equal this repository's build), that 2.2.0 is pinned in the registry and that the vault proxy
points to it, every transaction's sender and target, the events and exact amounts of the successful steps,
and the revert reason of every attack — **STRICT** from the execution traces saved in
`deployments/bsc-testnet/traces/` right after sending. The script asks several free public nodes in turn
(see "How long history lasts" in [TESTNET_V2.md](TESTNET_V2.md)); what no node asked can answer is reported
as OLD, never as passed.

Last run 2026-11-08 with the default nodes: **116 checks OK, 0 mismatches, 0 OLD** — all 12 attack reasons
STRICT, no tUSD left the vault (`deployments/bsc-testnet/verification/2026-11-08T1628Z-guards-report.txt` and the
raw node answers `2026-11-08T1628Z-guards-rpc-snapshot.json`). With `--build`: **122 checks OK** — the vault
implementation, the factory, the vault proxy and the three guards equal this repository's build byte for byte
(`2026-11-08T1632Z-guards-build-report.txt`).

## How it was run

```bash
forge script scripts/v2/DeployV22GuardDemo.s.sol:DeployV22GuardDemo --rpc-url $BSC_RPC_URL --broadcast --slow
forge script scripts/v2/RunV22GuardDemo.s.sol:RunV22GuardDemo --sig "allowed()" --rpc-url $BSC_RPC_URL --broadcast --slow
forge script scripts/v2/RunV22GuardDemo.s.sol:RunV22GuardDemo --sig "prepareAttacks()" --rpc-url $BSC_RPC_URL
python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2.2-guards-attacks.json
forge script scripts/v2/RunV22GuardDemo.s.sol:RunV22GuardDemo --sig "control()" --rpc-url $BSC_RPC_URL --broadcast
forge script scripts/v2/RunV22GuardDemo.s.sol:RunV22GuardDemo --sig "blockSupplier()" --rpc-url $BSC_RPC_URL --broadcast
forge script scripts/v2/RunV22GuardDemo.s.sol:RunV22GuardDemo --sig "prepareBlocked()" --rpc-url $BSC_RPC_URL
python scripts/v2/demo_attacks.py deployments/bsc-testnet/epk-v2.2-guards-blocked.json
python scripts/v2/build_v22_guards_evidence.py
```
