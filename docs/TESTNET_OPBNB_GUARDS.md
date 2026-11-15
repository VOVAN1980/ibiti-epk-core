# EPK guard demo — opBNB Testnet

Goal: the guard demo of BSC Testnet ([`TESTNET_GUARDS.md`](TESTNET_GUARDS.md)) on **opBNB**, BNB Chain's layer 2:
**DexGuard**, **ThreatFeed V2** and **CompositeGuard** protect a vault's trades — for an ordinary trading policy and
for autonomous AI-agent sessions — on the **real PancakeSwap V2 router** of opBNB Testnet (chainId 5611).

Status: **done on 2026-11-15** (00:51–00:56 UTC), on an EPKVault **2.3.0** created through the **public 2.3.0
factory of opBNB Testnet** (SDK `networks.opbnbTestnet.epk.factory`, the stack of [`TESTNET_OPBNB.md`](TESTNET_OPBNB.md)),
with the clocks of public test networks: the vault's timelock for loosening its settings is 5 minutes (production:
at least 1 hour). The guards are deployed from this repository's code. Testnet only, test funds only,
**not audited**. The main opBNB demo vault is a separate vault.

What this proves: the listed attacks were rejected on-chain in these scenarios, and allowed trades went through
at fair prices. It is **not** a guarantee that no other attack exists — see [`GUARDS_v2.md`](GUARDS_v2.md) §2 for
what the guards do not cover.

## Prices on opBNB: no Chainlink, and the official oracle is frozen

- **Chainlink has no price feeds on opBNB** (its list of data-feed networks has none). So the guard reads a
  **fixed test price for BNB: $578.49**, the answer of round 36893488147419194612 of Chainlink BNB / USD on BSC Testnet
  (`0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526`), copied when the demo was deployed. The check below asks a BSC Testnet node for that round
  and compares. A fixed price is enough for a run of a few minutes; it is not a price source for real use.
- **tUSD** is the demo's own test stablecoin with a fixed $1 feed. The demo admin created a tUSD/WBNB pool on
  the real PancakeSwap V2 router at the BNB test price (0.03 BNB + 17.35 tUSD). Only the admin can mint tUSD, so only the admin
  can move that pool's price.
- **The official opBNB oracle is frozen.** Binance Oracle publishes BNB / USD on opBNB Testnet (feed adapter
  `0x73110e…2419`; its documentation says the testnet feeds update every 24 hours). Its last update was on
  **2026-10-22 14:31 UTC at $732.37** — 23 days before this run and **27 % above** the Chainlink
  price. A second DexGuard with the same rules reads that feed (with 2 days of tolerance) and guards a second
  trading policy of the same operator key: step **A14** shows the guard refusing to trade on a stale price
  (`StalePrice`) instead of trading at a price 27 % off.

## Setup

- **Guard of the trading policy and of session envelope 1:** CompositeGuard = ThreatFeed V2 (checked first)
  + DexGuard (PancakeSwap V2 router only; tokens WBNB and tUSD; 1 % slippage against the test prices; swaps
  expire within 10 minutes; at most 0.001 BNB / 10 tUSD per trade).
- **Session envelope 2** has the same calls but no guard — to show that an agent cannot use it to reach the router.
- **PancakeSwap:** the router and the factory are the ones PancakeSwap's own SDK packages list for opBNB Testnet
  (`@pancakeswap/smart-router` `V2_ROUTER_ADDRESS`, `@pancakeswap/v2-sdk` `FACTORY_ADDRESS_MAP`).
- **Roles:** the same testnet keys as the BSC Testnet guard demo (local `.env`, never committed): admin, two
  guardians, recovery, session manager, operator (signs and submits the trading policy's batches), AI agent,
  ThreatFeed responder, a supplier (payee) and an attacker address that must never receive anything.
- **Not repeated on opBNB:** steps A3 and C1 of BSC Testnet (the real WBNB/BUSD pool far below Chainlink).
  opBNB Testnet has no official stablecoin on PancakeSwap: PancakeSwap's own token list for this network has only
  MOCK tokens A, B and C. The unlisted token of step A7 is PancakeSwap's MOCK Token A
  (`0x394d64eD40a6aF892D8562eE816D5e71D8999E52`). The step numbers are those of BSC Testnet; A14 is new.

## Contracts

| Contract | Address |
|---|---|
| EPKVault 2.3.0 implementation (the current public release) | [0x73a79604Bc39b1f6B57Cc68159EE3fc041Ac7Dd9](https://testnet.opbnbscan.com/address/0x73a79604Bc39b1f6B57Cc68159EE3fc041Ac7Dd9) |
| EPKRegistry of the public stack (5-minute test-network release window) | [0x81Ac99466291D2324bf459c7345F5506D9b90158](https://testnet.opbnbscan.com/address/0x81Ac99466291D2324bf459c7345F5506D9b90158) |
| EPKVaultFactory for 2.3.0 — the SDK's public factory | [0x67516e2Bb516D5cAa20408bE622fBAb57d31DEE4](https://testnet.opbnbscan.com/address/0x67516e2Bb516D5cAa20408bE622fBAb57d31DEE4) |
| EPKVault 2.3.0 guard demo vault (proxy) | [0x9390c190E3E1d900C7B7EbA197f8c6AF89B9949E](https://testnet.opbnbscan.com/address/0x9390c190E3E1d900C7B7EbA197f8c6AF89B9949E) |
| DexGuard (with the 2026-11-08 fixes) | [0xaD87B7Aea8F1139327A77EbB2203BC0B9640431C](https://testnet.opbnbscan.com/address/0xaD87B7Aea8F1139327A77EbB2203BC0B9640431C) |
| ThreatFeed V2 (ThreatFeedGuard) | [0xFe700A2445aE2c85Dd656FFA4cD73F5D0A4C4215](https://testnet.opbnbscan.com/address/0xFe700A2445aE2c85Dd656FFA4cD73F5D0A4C4215) |
| CompositeGuard (ThreatFeed V2 + DexGuard) | [0x327274073da2dCac166F20E68e2e7fD2fA15EDba](https://testnet.opbnbscan.com/address/0x327274073da2dCac166F20E68e2e7fD2fA15EDba) |
| DexGuard on the official opBNB oracle (Binance Oracle BNB / USD), same rules | [0xf8008FE1bD26792cCC286e5D41394470e510E239](https://testnet.opbnbscan.com/address/0xf8008FE1bD26792cCC286e5D41394470e510E239) |
| tUSD — the guard demo's test stablecoin (only the demo admin can mint) | [0xE3F4897CB9dC4b7FE980f81eFC997CDB9AE93Fa4](https://testnet.opbnbscan.com/address/0xE3F4897CB9dC4b7FE980f81eFC997CDB9AE93Fa4) |
| fixed $1 test feed for tUSD | [0x24E861F67180be06A65eF95874404D13FA9631F3](https://testnet.opbnbscan.com/address/0x24E861F67180be06A65eF95874404D13FA9631F3) |
| fixed BNB / USD test price, $578.49: copied from Chainlink BNB / USD on BSC Testnet (opBNB has no Chainlink feeds) | [0x38E841A9d917f8c7488A535Cf89c0F683D177027](https://testnet.opbnbscan.com/address/0x38E841A9d917f8c7488A535Cf89c0F683D177027) |
| PancakeSwap V2 router (opBNB Testnet, not ours) | [0x62FF25CFD64E55673168c3656f4902bD7Aa5F0f4](https://testnet.opbnbscan.com/address/0x62FF25CFD64E55673168c3656f4902bD7Aa5F0f4) |
| PancakeSwap tUSD/WBNB pool, created by the demo admin at the test BNB price | [0x8756a9cefff678f51e8c06b946a26af2ef52a40d](https://testnet.opbnbscan.com/address/0x8756a9cefff678f51e8c06b946a26af2ef52a40d) |
| Binance Oracle BNB / USD feed adapter (opBNB Testnet, not ours) | [0x73110e8602930f01bb584Bc683C5Aa2Fb4D42419](https://testnet.opbnbscan.com/address/0x73110e8602930f01bb584Bc683C5Aa2Fb4D42419) |

## What happened

| # | What | Transaction | Result |
|---|---|---|---|
| D1 | admin creates a tUSD/WBNB pool on PancakeSwap at the test BNB price (0.03 BNB + 17.3547511989 tUSD) | [0x09d48927…](https://testnet.opbnbscan.com/tx/0x09d489276742e25236040e12d9b492e602f5eacdafc57a50ad8595b0b5d89ee9) | success |
| D2 | admin creates a new EPKVault 2.3.0 through the PUBLIC 2.3.0 factory (5-minute test-network upgrade clocks) | [0xc4e05fb7…](https://testnet.opbnbscan.com/tx/0xc4e05fb7b24854953ce4b4f13bfbef51b9660990ce4b5e2fa99c4d43b3417bb2) | success |
| D3 | trading policy for the operator key, guarded by ThreatFeed V2 + DexGuard | [0x83f4a8ab…](https://testnet.opbnbscan.com/tx/0x83f4a8ab9604db14edb4944e968e84bd5d013dcf6b15dd4e869b7376be71eb56) | success |
| D3b | a second trading policy for the operator key, guarded by the same DEX rules priced by the official opBNB oracle (Binance Oracle BNB / USD) | [0x1a4a5955…](https://testnet.opbnbscan.com/tx/0x1a4a5955ea10bc28710af0d0ea5b63cd0d3f9ff763414e3f2dc2ec590ac64c90) | success |
| D4 | agent-session envelope 1 gets the same guard (envelope 2 stays unguarded on purpose) | [0x1fa5448a…](https://testnet.opbnbscan.com/tx/0x1fa5448ac9097cdbeb4f51f66feada561158b26a340f87c3002e930aa7970b44) | success |
| D5 | setup finished: from now on every loosening needs the 5-minute timelock | [0x472ed3ef…](https://testnet.opbnbscan.com/tx/0x472ed3ef57ebd933fd1f04c3d0a97be789378f6b54d53d6b739a9b7fb8750c79) | success |
| S1 | operator: vault swaps 0.0001 BNB for tUSD on PancakeSwap — at a fair price, output to the vault | [0xc8e4889b…](https://testnet.opbnbscan.com/tx/0xc8e4889b6cb89d2657c13851cb94404accf18309de8d924df83dbf51ea88fb3f) | success |
| S2 | operator: vault sells 0.05 tUSD for BNB (approve, swap, allowance reset) | [0xb02ba811…](https://testnet.opbnbscan.com/tx/0xb02ba8119f537d24234b76b901b7abf0d5cd3e09546858850fea46d829b4c4de) | success |
| S3 | operator: vault pays the supplier 1 tUSD (plain payments pass the guards) | [0x4ff5c51d…](https://testnet.opbnbscan.com/tx/0x4ff5c51d174e70a607c4598fbca50628bb72ad3a314966fc7c0ff539b4011a47) | success |
| S4 | session manager opens an AI-agent session in the GUARDED envelope 1 | [0xff77185e…](https://testnet.opbnbscan.com/tx/0xff77185e1b3126f2cadc72cb1fd73f7bdc1ff0cb5a7637e4530b477311499d02) | success |
| S5 | session manager opens an AI-agent session in the UNGUARDED envelope 2 | [0xecb46769…](https://testnet.opbnbscan.com/tx/0xecb467699f202b8a9865eb316d5a7f09cb7f5edbdc066877a6f7e0347da83470) | success |
| S6 | AI agent, on its own, swaps 0.0001 BNB for tUSD inside the guarded session | [0x8bdb4b56…](https://testnet.opbnbscan.com/tx/0x8bdb4b56f3388530e805af6adb9b9891220fa54336b2f9efaa4768620a0011f8) | success |
| A1 | operator key signs a swap whose output goes to the attacker | [0x70eeb90b…](https://testnet.opbnbscan.com/tx/0x70eeb90b5d165c27bc5cbbe3ccddc4a89e265b780a7ea6f3145cd2b899159244) | **rejected**: `RecipientNotVault` |
| A2 | operator key signs a swap that accepts any price (minimum out = 1) | [0x1558d52c…](https://testnet.opbnbscan.com/tx/0x1558d52c520a837acbcb3c710e13b403f1722d2a31890349b579af8283f613ae) | **rejected**: `PriceTooLow` |
| A4 | operator key uses an unsupported router function (fee-on-transfer variant) | [0x9c634a29…](https://testnet.opbnbscan.com/tx/0x9c634a29fca1e304cb938bdb4636539edb7b1f1e9a6b5068f184cae4695596a0) | **rejected**: `UnsupportedCall` |
| A5 | operator key signs a swap valid for 2 days (to run later at a worse price) | [0x820db8c9…](https://testnet.opbnbscan.com/tx/0x820db8c9917014dc164af49f64f5a589fc12cd5b94521c6287360f10bf822c08) | **rejected**: `BadDeadline` |
| A6 | operator key approves a non-router (the supplier) to pull tUSD | [0x16e3b5f7…](https://testnet.opbnbscan.com/tx/0x16e3b5f7e44aa8bb95ab9bafe07b8e289bafbc2d4083ca45126b18647326dbed) | **rejected**: `ApproveToNonRouter` |
| A7 | operator key swaps into a token that is not on the guard's list (PancakeSwap's MOCK Token A) | [0x76e194cc…](https://testnet.opbnbscan.com/tx/0x76e194cc9cb88e82d34a24b3f1220783e06c4869cf9ecf6f52fe60bb44024fc3) | **rejected**: `TokenNotAllowed` |
| A8 | AI agent (guarded session) sends a swap's output to the attacker | [0x09b0086f…](https://testnet.opbnbscan.com/tx/0x09b0086f0eac57c9e3c653a1f28843eff2a9195ba5508381678c7916ef72af89) | **rejected**: `RecipientNotVault` |
| A9 | AI agent uses the UNGUARDED session to call the router — the other path | [0x137d273f…](https://testnet.opbnbscan.com/tx/0x137d273ff770be95908e66bed4411d4dd8d4ba1e840e4d937db8797938516f7c) | **rejected**: `GuardRequired` |
| A10 | admin key tries to remove the session guard without the timelock | [0x988111bb…](https://testnet.opbnbscan.com/tx/0x988111bbbe325589464c8822d749d23ee2d83e8e47166d97556e53c49db3e8e3) | **rejected**: `NotTimelocked` |
| A11 | operator key parks 1 tUSD at the router, where anyone could sweep it | [0x0b2982cb…](https://testnet.opbnbscan.com/tx/0x0b2982cb1852309abfdd6789a5b46e9c6a36425b658c7d0072b6d8c6a8727c86) | **rejected**: `RecipientNotAllowed` |
| A14 | operator key, second policy: a fair swap priced by the official opBNB oracle (Binance Oracle BNB / USD), whose feed last updated on 2026-10-22 | [0xaf69d9b3…](https://testnet.opbnbscan.com/tx/0xaf69d9b369dfd81a9df47e2bf901e012a6913b560dcf4588a2fec1ebca744dc6) | **rejected**: `StalePrice` |
| A12 | ThreatFeed V2: a responder blocks the supplier (reported as a drainer) — instantly | [0x57b273c3…](https://testnet.opbnbscan.com/tx/0x57b273c3486787d6dcd9e9c350cb304847b6583f2a4281a62db8295f31c4ac39) | success |
| A13 | after the block: operator key tries to pay the supplier again | [0xb9b93366…](https://testnet.opbnbscan.com/tx/0xb9b9336656d7c82a68decc5cf7b1f3a2c26a74dd047b22aa0044a488e969278e) | **rejected**: `BlockedAddress` |

The vault's own trade (S1) received 0.0575 tUSD for 0.0001 BNB — 99.4 % of its value at the test price — and
the AI agent's trade inside the guarded session (S6) 0.0575 tUSD (99.3 %). During all attacks not a single
tUSD left the vault, and the attacker address received nothing.

## Check it yourself

```bash
python scripts/v2/verify_evidence.py --network opbnb-testnet --evidence deployments/opbnb-testnet/epk-guards-evidence.json --doc docs/TESTNET_OPBNB_GUARDS.md
```

Python 3 only — no Foundry, no keys. It checks the chain id, every contract's code hash (and, with `--build` after
`git checkout debb154 && forge build` — the source these contracts were built from —, that the vault
implementation, the factory, the vault proxy, the four guards, tUSD and the two fixed feeds equal this repository's
build), that the implementation is pinned in the registry and that the vault proxy points to it, the fixed test
prices (and, from a BSC Testnet node, the Chainlink round the BNB price was copied from), every transaction's sender
and target, the events and exact amounts of the successful steps, and the revert reason of every attack — by
**REPLAY**, because no free opBNB node offers execution traces (how long nodes keep history: [`TESTNET_OPBNB.md`](TESTNET_OPBNB.md#check-it-yourself)).
What no node asked can answer is reported as OLD, never as passed.

Last run 2026-11-15, right after the demo, with the default nodes: **129 checks OK, 0 mismatches, 0 OLD** — all 12
attack reasons proven by REPLAY, the BNB test price equals the Chainlink round it was copied from, no tUSD left the
vault during any attack (`deployments/opbnb-testnet/verification/2026-11-15T0107Z-guards-report.txt` and the raw node answers
`2026-11-15T0107Z-guards-rpc-snapshot.json`). With `--build`: **139 checks OK** — the vault implementation, the factory, the vault
proxy, the four guards, tUSD and the two fixed feeds equal this repository's build byte for byte
(`2026-11-15T0107Z-guards-build-report.txt`).

The same checks run in any browser, with no installation: [`docs/proof/guards.html?net=opbnb`](proof/guards.html)
("Protected swaps", switch to opBNB Testnet) loads the evidence file from a fixed Git commit and checks it live
against the chain.

## How it was run

Gas money came from BSC Testnet through BNB Chain's official bridge (see [`TESTNET_OPBNB.md`](TESTNET_OPBNB.md)).
From the repo root, with `$RPC` = `https://opbnb-testnet-rpc.bnbchain.org` (Foundry loads `.env`); the scripts
write to `deployments/opbnb-testnet/`:

```bash
forge script scripts/v2/DeployGuardDemo.s.sol:DeployGuardDemo --rpc-url $RPC --broadcast --slow
forge script scripts/v2/RunGuardDemo.s.sol:RunGuardDemo --sig "allowed()" --rpc-url $RPC --broadcast --slow
forge script scripts/v2/RunGuardDemo.s.sol:RunGuardDemo --sig "prepareAttacks()" --rpc-url $RPC
python scripts/v2/demo_attacks.py deployments/opbnb-testnet/epk-guards-attacks.json
forge script scripts/v2/RunGuardDemo.s.sol:RunGuardDemo --sig "blockSupplier()" --rpc-url $RPC --broadcast
forge script scripts/v2/RunGuardDemo.s.sol:RunGuardDemo --sig "prepareBlocked()" --rpc-url $RPC
python scripts/v2/demo_attacks.py deployments/opbnb-testnet/epk-guards-blocked.json
python scripts/v2/build_guards_evidence.py --network opbnb-testnet
```

`DeployGuardDemo` reads the latest Chainlink BNB / USD round on BSC Testnet through a BSC Testnet node
(`BSC_RPC_URL`, else a public one) before it deploys the fixed test price.
