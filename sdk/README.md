# @ibiti/epk-sdk

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
