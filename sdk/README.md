# @ibiti/epk-sdk

TypeScript SDK for **EPK** (IBITI Labs) built on **viem**.

- `@ibiti/epk-sdk/v2` — **EPK v2 vaults (2.0.x and 2.1.x), AI-agent sessions, the timelock and the guards**
  (DexGuard, ThreatFeed V2, CompositeGuard). In development, like EPK 2.1 itself.
- `@ibiti/epk-sdk` — EPK v1 kernel (legacy reference), documented further below.

## SDK v2 in five calls

```ts
import { createPublicClient, createWalletClient, http } from "viem";
import { bscTestnet } from "viem/chains";
import { EPKVaultClient, planGuardedSwap } from "@ibiti/epk-sdk/v2";

const publicClient = createPublicClient({ chain: bscTestnet, transport: http() });
const vault = new EPKVaultClient({ address: VAULT, publicClient });

// 1. plan a swap the guard will accept (reads Chainlink fair value and the pool quote; throws if the
//    pool is off the market — the trade would be refused on-chain anyway)
const plan = await planGuardedSwap({ publicClient, guard: DEX_GUARD, router: ROUTER, vault: VAULT,
  path: [WBNB, USDT], amountIn: 10n ** 15n, native: true });
// 2. sign the batch with the bot's / agent's key (EIP-712, identical to the vault's digest)
const signed = await vault.signBatch({ policyId, agent: botAddress, calls: plan.calls, signer: botWallet });
// 3. dry-run: { ok: true } or the decoded reason, e.g. PriceTooLow, BudgetExceeded, GuardRequired
const sim = await vault.simulate({ policyId, calls: plan.calls, deadline: signed.deadline, signature: signed.signature, agent: botAddress });
// 4. submit (the bot's wallet is the agent the batch was signed for)
if (sim.ok) await new EPKVaultClient({ address: VAULT, publicClient, walletClient: botWallet })
  .execute({ policyId, calls: plan.calls, deadline: signed.deadline, signature: signed.signature });
```

### Opt-in upgrades and live events

```ts
import { EPKUpgrader, watchVault } from "@ibiti/epk-sdk/v2";

const upgrader = new EPKUpgrader(VAULT, publicClient, adminWallet);
const stop = watchVault(publicClient, VAULT, (e) => console.log(e)); // scheduled changes arrive decoded and labelled
const { operationId } = await upgrader.schedule(NEW_RELEASE, salt);   // may run during the release window
const s = await upgrader.status(NEW_RELEASE, salt, fromBlock);        // "waiting" | "ready" | …, executableAt
if (s.state === "ready") await upgrader.execute(NEW_RELEASE, salt);   // same address, same funds
```

On public test networks the whole cycle takes about 5 minutes (same code as mainnet, minute-scale
delays); on mainnet the release window is 7 days and the vault's own wait runs in parallel.

Also: `availableToSpend` / `budgetAvailable` (limits left), `openSession` (AI-agent sessions),
`schedule` / `executeScheduled` / `cancel` + `hashOperation` (timelock), `envelopeGuard`, `DexGuardClient`
(`minimumOut`, `maximumIn`, `price`), `isCallBlocked` (ThreatFeed V2), batch builders `v2SwapExactTokens`,
`v2SwapExactNative`, `v2SwapExactTokensForNative`, and `decodeEpkError` for every vault and guard error.

```bash
npm run test:v2      # offline: digest and operation ids equal the live vault's; all 11 on-chain rejections decode
npm run example:v2   # read-only walkthrough against the EPK 2.1 demo vault on BSC Testnet (signs and simulates, sends nothing)
npm run example:v2-upgrade   # opt-in upgrade on BSC Testnet driven by the SDK (needs the demo admin key; sends transactions)
```

How the guards work and what they do not cover: [`docs/GUARDS_v2.md`](../docs/GUARDS_v2.md).

---

## EPK v1 SDK (legacy reference)

TypeScript SDK for **Eternal Permission Kernel (EPK) v1** (IBITI Labs) built on **viem**.

Goal: a small, practical SDK that:
- exposes typed-ish viem contract instances
- ships the **ABI bundle**
- provides runnable examples (including **execute → revoke → PolicyInactive()** proof)

Version: **v1.0.0**

---

## What you get

- `createEPKContracts({ publicClient, walletClient?, addresses })`
- ABI bundle:
  - `EPKernel`
  - `CompositeValidator`
  - `TargetSelectorGuard`
  - `SpendLimitValidator`
  - `ThreatFeedBlocklistValidator`

---

## Requirements

- Node.js **>= 18**
- Foundry is required **only** for `npm run sync-abi` (it calls `forge build` in repo root)

---

## Install

### Local (recommended while developing)

From any consumer project folder:

```bash
npm i file:../ibiti-epk-core/sdk
```

### Registry (later, if you publish)

```bash
npm i @ibiti/epk-sdk
```

---

## Quick start (read-only)

```ts
import { createPublicClient, http } from "viem";
import { bscTestnet } from "viem/chains";
import { createEPKContracts } from "@ibiti/epk-sdk";

const rpcUrl =
  process.env.BSC_RPC_URL ?? "https://data-seed-prebsc-1-s1.binance.org:8545";

const publicClient = createPublicClient({
  chain: bscTestnet,
  transport: http(rpcUrl),
});

const contracts = createEPKContracts({
  publicClient,
  addresses: {
    EPKernel: "0x0beEB0083C576B54DB99B4abEF0Dcbc5Bc70bF82",
  },
});

console.log("chainId", await publicClient.getChainId());
console.log("EPKernel", contracts.EPKernel?.address);
```

---

## Environment variables

Copy `.env.example` to `.env` in this folder and fill it in. `sdk/.env` is git-ignored — **never commit real keys**.

### Common

| Variable | Meaning |
|---|---|
| `BSC_RPC_URL` | RPC endpoint (testnet/mainnet). Fallback in examples: `https://data-seed-prebsc-1-s1.binance.org:8545` |
| `EPKERNEL` | Kernel address |
| `COMPOSITE_VALIDATOR`, `TARGET_SELECTOR_GUARD`, `SPEND_LIMIT_VALIDATOR`, `THREATFEED_BLOCKLIST_VALIDATOR` | Validator addresses (used by `example:smoke`) |

### Write examples (`example:setup`, `example:write`)

| Variable | Meaning |
|---|---|
| `OWNER_PRIVATE_KEY` | Owner EOA private key (`0x...`) |
| `AGENT_PRIVATE_KEY` | Agent EOA private key (`0x...`) |
| `MOCKTARGET` | Target contract (helper) used by the example |
| `POLICY_ID` | Policy id to execute — printed by `npm run example:setup` |

Example `sdk/.env` (do not commit):

```dotenv
BSC_RPC_URL=https://data-seed-prebsc-1-s1.binance.org:8545

EPKERNEL=0x0beEB0083C576B54DB99B4abEF0Dcbc5Bc70bF82
MOCKTARGET=0x01dc1612edB74D42e6dbd9cd0D4cF08a40757d12
POLICY_ID=4

OWNER_PRIVATE_KEY=0x...
AGENT_PRIVATE_KEY=0x...
```

---

## Scripts

Run from `ibiti-epk-core/sdk`.

| Command | What it does |
|---|---|
| `npm run build` | `sync-abi` → TypeScript build to `dist/` → `postbuild` copies `src/abi` to `dist/abi` (so the package ships ABIs) |
| `npm run sync-abi` | Runs `forge build` in repo root and copies ABIs into `src/abi` |
| `npm run typecheck` | Type-check without emitting |
| `npm run example:smoke` | Read-only check of deployed contracts |
| `npm run example:setup` | Create a policy, allow the agent and the call; prints `POLICY_ID` |
| `npm run example:write` | Execute + security demos (replay, disallowed call, nonce bump, revoke) |

### Example: execute + security demos (proof)

```bash
npm run example:setup   # once: creates a policy, prints POLICY_ID for sdk/.env
npm run example:write
```

Expected:

1. good execute `setX(123)` succeeds
2. replay of the same signature reverts with `NonceTooLow()`
3. call with a disallowed selector reverts with `CallNotAllowed()`
4. `emergencyNonceBump` kills a queued signature (`NonceTooLow()`)
5. after revoke, execute reverts with `PolicyInactive()`

---

## Folder structure

```text
sdk/
  src/
    abi/                 # generated from Foundry out/
    index.ts
    kernel.ts
    types.ts
  dist/                  # build output (published files, git-ignored)
    abi/                 # copied from src/abi
  examples/              # runnable scripts (not part of build output)
  scripts/               # internal helpers (e.g., ABI sync)
```

---

## Notes

- If Solidity contracts changed: run `npm run build` (or `npm run sync-abi`).
- JSON imports use modern ESM form: `with { type: "json" }`.

## License

MIT
