# Integrating EPK v2 — developer guide (TypeScript SDK)

For teams that run trading bots, AI agents or payment automation and want their funds in a vault that a
hacked server, a stolen bot key or a misbehaving agent cannot drain. Everything below runs today on **BSC
Testnet** with `@ibiti/epk-sdk/v2` (`sdk/` in this repository). EPK is **not audited and not on mainnet**;
production use of the contracts needs a commercial license (BUSL-1.1, see [`LICENSING.md`](../LICENSING.md)).
The SDK itself is MIT.

**Install** (preview on npm, testnet only):

```bash
npm install @ibiti/epk-sdk@preview viem
```

```ts
import { networks, EPKFactoryClient, VaultAdmin, vaultActions, EPKVaultClient } from "@ibiti/epk-sdk/v2";
```

`npm run check:package` (in `sdk/`) proves this works for an outside team: it installs the package into a
clean empty project — from the local build, or `FROM_NPM=@ibiti/epk-sdk@preview` straight from npm — then
type-checks a TypeScript file against it and reads BSC Testnet through it.

**Fastest start:** `sdk/examples/v2-quickstart.ts` creates your own vault from zero with one funded testnet
key, configures it, lets a bot pay, and shows what a stolen bot key gets back — about 40 seconds
([real run](../deployments/bsc-testnet/v2.1/2026-11-07-sdk-quickstart.log)):

```bash
cd sdk && npm ci
ADMIN_PRIVATE_KEY=0x… npx tsx examples/v2-quickstart.ts
```

## 1. The model in one minute

| Piece | What it is |
|---|---|
| **Vault** | Your own contract (proxy, permanent address). Funds live here, not in a bot wallet. |
| **Admin** | Configures the vault. During setup changes are instant; after `finalizeSetup` every loosening change waits in a **timelock** (≥ 1 hour). |
| **Guardians (≥ 2)** | Independent keys or services (e.g. the EPK Watchtower). They can only **stop** — pause, cancel a scheduled change, tighten — never move funds. |
| **Recovery** | A cold key that can replace a lost admin through the timelock. |
| **Limits** | Per asset, per window, measured on real balance changes. Everything that leaves the vault counts. |
| **Destinations** | The only addresses that may receive funds, approvals or native value. |
| **Policy** | A bot / operator key: which calls it may make (`target + function`), value per call, optional **guard**. |
| **Session** | An AI agent's short-lived key with its own budget, opened instantly inside an **envelope** the owner approved. |
| **Guard** | Extra rules per policy / envelope: **DexGuard** (safe swaps against Chainlink prices), **ThreatFeed V2** (blocklist), **CompositeGuard** (both). |

## 2. Create a vault

```ts
import { networks, EPKFactoryClient } from "@ibiti/epk-sdk/v2";

const factory = new EPKFactoryClient(networks.bscTestnet.epk.factory, publicClient, adminWallet);
const { vault } = await factory.createVault({
  guardians: [guardian1, guardian2], // independent: another device, the Watchtower, a partner
  delay: 3600n,                      // timelock for loosening changes after setup
  recovery: coldKey,
  salt: keccak256(toBytes("my-vault-1")),
});
```

`predictVault(...)` returns the address before it exists. The caller is always the admin — nobody can
create a vault "for" you.

## 3. Configure, then go live

```ts
import { VaultAdmin, vaultActions, NATIVE, NATIVE_TRANSFER, selector } from "@ibiti/epk-sdk/v2";

const admin = new VaultAdmin(vault, publicClient, adminWallet);
const { policyIds: [botPolicy] } = await admin.apply([
  vaultActions.setAsset(USDT, parseUnits("1000", 18), 86_400),       // ≤ 1000 USDT per day leaves the vault
  vaultActions.addDestination(TREASURY),                              // the only payee
  vaultActions.createPolicy(BOT, 0, 0n),                              // the bot's policy (add a guard for trading)
]);
await admin.apply([
  vaultActions.setAgent(botPolicy, BOT),
  vaultActions.setCall(botPolicy, USDT, selector("transfer(address,uint256)")),
]);
await admin.finalizeSetup(); // from now on: loosening changes go through the timelock
```

After `finalizeSetup`, the same `admin.apply([...])` **schedules** each change in the timelock and returns
the operations; guardians and the Watchtower see them and can veto. Run them later with
`admin.executeScheduled(result.scheduled)`. Tightening (pause, remove a destination, lower a limit) stays
instant for the admin and every guardian.

## 4. Let the bot act

```ts
const vaultAsBot = new EPKVaultClient({ address: vault, publicClient, walletClient: botWallet });
const calls = [{ target: USDT, value: 0n, data: encodeFunctionData({ abi: erc20Abi, functionName: "transfer", args: [TREASURY, amount] }) }];
const signed = await vaultAsBot.signBatch({ policyId: botPolicy, agent: BOT, calls, signer: botWallet });
const check = await vaultAsBot.simulate({ policyId: botPolicy, calls, deadline: signed.deadline, signature: signed.signature, agent: BOT });
if (check.ok) await vaultAsBot.execute({ policyId: botPolicy, calls, deadline: signed.deadline, signature: signed.signature });
else console.log(explainEpkError(findRevertData(check.raw)!)); // e.g. "LimitExceeded(...): … → wait for the window to refill"
```

`availableToSpend(token)` shows what is left in the current window.

## 5. AI-agent sessions

```ts
await admin.apply([
  vaultActions.setSessionManager(BACKEND),                          // your backend opens sessions
  vaultActions.setEnvelope(1n, true, 86_400, 0n),                   // sessions live ≤ 1 day
  vaultActions.setEnvelopeCall(1n, USDT, selector("transfer(address,uint256)")),
  vaultActions.setEnvelopeBudgetCap(1n, USDT, parseUnits("50", 18)), // each session ≤ 50 USDT per day
  vaultActions.setEnvelopeGuard(1n, GUARD),                         // needed for anything beyond transfers
]);
// later, instantly, from the backend:
await new EPKVaultClient({ address: vault, publicClient, walletClient: backendWallet })
  .openSession({ envelopeId: 1n, signer: AGENT, agent: AGENT, validUntil: BigInt(now + 3600) });
```

A session id is `2^128 + n`; the agent signs and submits its own batches exactly like a bot (§4). A session
**without** a guard can only make transfers and approvals the vault inspects itself — swaps and other calls
are refused (`GuardRequired`).

## 6. Trading safely (DexGuard)

```ts
import { deployDexGuard, deployThreatFeed, deployCompositeGuard, planGuardedSwap } from "@ibiti/epk-sdk/v2";

const dex = await deployDexGuard(adminWallet, publicClient, {
  wrappedNative: networks.bscTestnet.dex.wbnb, maxSlippageBps: 100n, maxDeadline: 600n,
  routers: [{ router: networks.bscTestnet.dex.pancakeV2Router, kind: "V2" }],
  tokens: [{ token: WBNB, feed: networks.bscTestnet.chainlink["BNB/USD"], maxAge: 86_400, maxAmountIn: parseEther("1"), minPrice: 10n ** 8n, maxPrice: 10n ** 13n }, /* … */],
});
const plan = await planGuardedSwap({ publicClient, guard: dex, router, vault, path: [WBNB, USDT], amountIn, native: true });
// plan.calls → signBatch / execute as in §4. planGuardedSwap throws if the pool is off the Chainlink price.
```

What DexGuard blocks and what it does not cover: [`GUARDS_v2.md`](GUARDS_v2.md). Live proof:
[`TESTNET_V21.md`](TESTNET_V21.md).

## 7. Watch, react, upgrade

- `watchVault(publicClient, vault, onEvent)` — scheduled changes arrive decoded and labelled ("allow
  payments to a new address", "UPGRADE the vault's code"), plus batches, outflows, pauses, upgrades.
  Run the [Watchtower](../watchtower/README.md) as a guardian to cancel what you did not plan.
- `explainEpkError(data)` — every vault and guard error in one sentence plus what to do.
- `EPKUpgrader` — opt into a newer release: `schedule`, `status`, `execute`. Test networks: ~5 minutes;
  mainnet: 7-day public release window with the vault's own wait running in parallel
  ([`TESTNET_V21_FAST_UPGRADE.md`](TESTNET_V21_FAST_UPGRADE.md)).

## 8. Checklist before real money

- [ ] One key per role; admin and recovery offline, guardians on independent infrastructure.
- [ ] Limits sized to what you can afford to lose in one window; per-session budgets smaller still.
- [ ] Only your own addresses as destinations; every trading policy / envelope has a guard.
- [ ] The Watchtower (or your own monitor) runs as a guardian and alerts a human.
- [ ] You rehearsed `pause` / `panic` and recovery on testnet.
- [ ] EPK has been independently audited (not yet) and you hold a commercial license for production use.
