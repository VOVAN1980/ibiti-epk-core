# @ibiti/epk-sdk

> **Preview — testnet only.** EPK v2 has **not** been independently audited and is not deployed on any mainnet.
> Do not use this SDK or EPK v2 to hold or move real funds. Install, integrate on BSC Testnet, and tell us what
> is missing: info@ibiticoin.com · https://github.com/VOVAN1980/ibiti-epk-core
>
> `npm install @ibiti/epk-sdk@preview viem` · developer guide:
> [INTEGRATION_v2.md](https://github.com/VOVAN1980/ibiti-epk-core/blob/master/docs/INTEGRATION_v2.md) ·
> licence: SDK code MIT; bundled EPK v2 contract bytecode BUSL-1.1 (see `LICENSE`).

TypeScript SDK for **EPK** (IBITI Labs) built on **viem**: EPK vaults (2.0.x and 2.1.x), AI-agent sessions,
the timelock and the guards (DexGuard, ThreatFeed V2, CompositeGuard). In development, like EPK 2.1 itself.
`@ibiti/epk-sdk` and `@ibiti/epk-sdk/v2` export the same API.

## Start here

**[Developer guide: integrate EPK v2](https://github.com/VOVAN1980/ibiti-epk-core/blob/master/docs/INTEGRATION_v2.md)** — create your own vault, configure it, let a
bot or AI agent act, trade safely, watch and upgrade.

```bash
# from a clone of the repository (examples are not in the npm package):
cd sdk && npm ci && cp .env.example .env   # put a separate, funded testnet key into ADMIN_PRIVATE_KEY
npm run example:v2-quickstart              # your own vault on BSC Testnet from zero, ~40 s, ~0.005 tBNB
```

New in the SDK for integrators: `EPKFactoryClient` (create / predict your vault), `VaultAdmin` + `vaultActions`
(configure during setup, the timelock afterwards), `deployDexGuard` / `deployThreatFeed` / `deployCompositeGuard`,
`networks` (public BSC Testnet addresses, PancakeSwap, Chainlink feeds), `explainEpkError` (every error in one
sentence plus what to do).

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

How the guards work and what they do not cover: [`docs/GUARDS_v2.md`](https://github.com/VOVAN1980/ibiti-epk-core/blob/master/docs/GUARDS_v2.md).

## License

SDK code: MIT. The bundled guard creation bytecode is EPK v2 contract code under BUSL-1.1 — see `LICENSE`
and [LICENSING.md](https://github.com/VOVAN1980/ibiti-epk-core/blob/master/LICENSING.md).
