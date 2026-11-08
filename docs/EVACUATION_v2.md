# Emergency evacuation to the owner's cold wallet — design and threat model

Status: **design agreed by the owner on 2026-11-08** (option C, §4; both decisions of §8 "yes"); **implemented in
this repository for vault release 2.3.0** (roadmap item 6a): the `EPKVaultEmergency` module, 22 tests in
`test/v2/EPKVault.evacuation.t.sol` (attacks E1–E11, the size guard; E12 is the existing rule that ordinary
operations die with an upgrade), the Watchtower's COLD WALLET CHANGE alarm and the SDK's vault ABI. Nothing here
is deployed yet. It ships to BSC Testnet only with
the attack tests of §7, and before any mainnet it must pass an independent security review.

Evacuation is an emergency function for a hack or a loss of control. Ordinary withdrawals never need it: they
work as today, through policies, sessions and the timelock.

## 1. What it is for

A vault's protections today stop money from leaving the wrong way: limits, allowed destinations, sessions,
guards, the timelock, guardian vetoes and `panic`. But after a `panic` the money is still **in the vault**. That
matters when the vault itself is the risk:

- a bug in the vault or a guard is found (EPK is not audited yet) and the code could be exploited before a fix;
- a release in the registry turns out to be bad while vaults are scheduled to take it;
- the admin key **and** another protective key are compromised, and the owner wants the money out of reach
  while the incident is investigated.

**Evacuation** moves the vault's funds, in one transaction, to **one address the owner registered long in
advance — their own cold wallet** (a hardware wallet or a multisig). It is a lifeboat, not a payment path:
nobody can choose where the money goes, how much, or attach any call.

## 2. Proposed behaviour

| Item | Proposal |
|---|---|
| `coldWallet` | one address per vault (new storage, appended). Zero = evacuation is off |
| Setting it | during setup: directly by the admin. After setup: only through the timelock with `setColdWallet(address)`, waiting **max(3 × delay, 2 days)** on production networks and **3 × delay** on test networks (15 minutes with the 5-minute test delay). Any guardian or the recovery key can cancel it; a `panic` cancels it |
| Allowed values | not zero, not the vault, not the admin, a guardian, the recovery key, the session manager or the co-signer — the cold wallet must not share a key with any role that runs the vault |
| `evacuate(address[] tokens)` | callable by a **protective role** (see §4). Sends the **whole balance** of each listed asset to `coldWallet`; an empty list means every tracked asset. Only tracked assets and native coin; nothing else is called |
| Side effects | the same as `panic`: the vault is paused and every policy, session and pending ordinary change is revoked (epoch bump). Limits are neither checked nor consumed: this is the only unlimited path, and its destination is fixed |
| A token that refuses | the whole call reverts and names the token; evacuate again without it (the list parameter exists for this) |
| Events | `ColdWalletSet(address)`, `Evacuated(address token, uint256 amount, address to, address by)` |
| Errors | `NoColdWallet()`, `NotProtectiveRole()`, `UntrackedAsset(token)` (existing), `BadRole(address)` (existing) |

Untracked tokens are never touched by evacuation: calling an arbitrary contract under the vault's identity is
exactly what EPK forbids. The owner moves them through an ordinary timelocked operation.

## 3. Invariants — must hold after this change, proven by tests

1. **Fixed destination.** No caller can choose the recipient, the amount or calldata of an evacuation.
2. **No fast redirect.** `coldWallet` changes only through the timelock (max(3 × delay, 2 days) in production),
   vetoable by every guardian and the recovery key, cancelled by `panic`, never by a policy, session or agent.
3. **No new spending role.** Agents, policy signers, the session manager and the co-signer can never evacuate;
   a batch can never call `evacuate` or `setColdWallet` (the vault already refuses itself as a call target).
4. **No reentrancy.** `evacuate` shares the vault's reentrancy lock; a cold wallet contract that calls back while
   receiving native coin is refused.
5. **Evacuation never leaves funds anywhere else.** For every asset, the vault's balance drop equals the cold
   wallet's balance gain (fee-on-transfer tokens: the event records what the vault sent; the test checks no
   third address received anything).
6. **Everything else is unchanged.** All existing tests pass; the vault's other rules are the same.

## 4. Who may trigger it — the main decision

Today the vault keeps a strict line: **guardians can stop everything but can never move funds** (the Watchtower
README promises this). Evacuation crosses that line — funds move, but only to the owner's own cold wallet.

| Option | Who may evacuate | Gain | Cost |
|---|---|---|---|
| **A** | admin and recovery key | guardians stay "cannot move funds" | the Watchtower can only `panic`, a human must evacuate |
| **B** (roadmap text) | admin, recovery key **and every guardian** | fastest: the Watchtower can evacuate on its own | a stolen guardian key can force funds into the cold wallet (disruption, not theft); theft needs the cold wallet key **plus** any guardian key |
| **C** | admin, recovery key, and **one optional `evacuator` address** the owner sets through the timelock (e.g. a Watchtower) — off by default | automation only where the owner asks for it; guardians keep their promise | one more role to explain and test |

**Chosen: C.** It keeps the clear guardian rule, lets an owner switch on automatic evacuation by a
Watchtower deliberately, and keeps theft requiring the cold wallet key plus a key the owner picked for this
job. If the extra role costs too much code size (§6), fall back to A, not B.

## 5. Threat model — attacks and expected results

| # | Attacker holds | Tries to | Expected result |
|---|---|---|---|
| E1 | an agent / session / policy key | call `evacuate`, or put `evacuate` / `setColdWallet` in a batch | refused (`NotProtectiveRole`; `BadTarget` for the batch) |
| E2 | the admin key | set the cold wallet to their own address and evacuate | the change waits max(3 × delay, 2 days); the Watchtower or any guardian cancels it; a `panic` kills it; evacuation meanwhile goes only to the old cold wallet |
| E3 | the admin key | evacuate to grief the owner | funds land in the owner's cold wallet; the vault is paused — disruption, no loss |
| E4 | a guardian key (option B only) / the evacuator key (option C) | evacuate repeatedly | as E3; the owner removes the key through the timelock |
| E5 | the cold wallet key only | get funds out | nothing: the cold wallet cannot trigger evacuation |
| E6 | the cold wallet key **and** a trigger key | steal everything | possible by design — this is why the cold wallet must be offline (hardware or multisig) and never share a key with a vault role (§2) |
| E7 | the recovery key | redirect the cold wallet | cannot schedule it (admin only); can only cancel |
| E8 | a malicious cold wallet contract | re-enter the vault while receiving coin | refused by the shared reentrancy lock |
| E9 | a token that reverts or charges fees | block the evacuation of other assets | the call names the token; evacuate the rest with an explicit list; fee tokens: no third party gains |
| E10 | an attacker racing the owner | schedule a cold-wallet change right after a panic | the change is a normal (not panic-exempt) operation: the next `panic` or any guardian kills it |
| E11 | anyone | evacuate when no cold wallet is set | refused (`NoColdWallet`) |
| E12 | the admin key, after an upgrade | rely on a cold-wallet change scheduled under the previous release | dies with the upgrade (ordinary operations are bound to the release that scheduled them) |

## 6. Engineering constraint: code size

`EPKVault` 2.3.0 is **24,145 bytes**; the EIP-170 limit is 24,576. **431 bytes** remain. Evacuation needs new
storage, two functions, a loop over the tracked assets and two events — plausibly 400–700 bytes.

**Measured (2026-11-08):** with evacuation inside the vault, `EPKVault` is 25,587 bytes — 1,011 over the
limit. So the code lives in a module:

- `EPKVaultLayout` holds the vault's storage (unchanged slots, append-only); `EPKVault` and the new
  `EPKVaultEmergency` both inherit it, so they always agree on every slot.
- Each implementation **deploys its own `EPKVaultEmergency` in its constructor** and keeps the address as an
  immutable. The module is therefore part of the same release: the registry's pin of the implementation fixes
  the address, and the code at that address was created by the implementation's own creation code (checked
  byte for byte against this repository's build like every contract in the evidence).
- `evacuate`, `setColdWallet` and `setEvacuator` are called **on the vault** (interface `IEPKVaultEmergency`,
  in the SDK's vault ABI). The vault has no code of its own for them: its fallback runs the module's code on the
  vault's storage (`delegatecall`); the module has no other functions, so any other unknown call still reverts.
  Called directly, the module has no admin, no cold wallet and no assets, so every call fails.
- Never by removing protections or the views the SDK and scripts rely on (`getExecuteDigest`, …).

Storage: `coldWallet` is appended after all existing storage (the layout stays append-only, checked against the
`storageLayout` of 2.2.0). Vaults upgrading from 2.0–2.2 start with no cold wallet: evacuation stays off until
the owner registers one through the timelock.

## 7. Tests before any deployment

- **Unit and attack tests** for E1–E12 and every row of §2 (who, what, where, events, errors, pause and epoch).
- **Invariant / fuzz test:** in any sequence of calls by any roles, funds only ever leave the vault to allowed
  destinations within limits, or to `coldWallet` through `evacuate` — never anywhere else.
- **Upgrade test:** a 2.2.0 vault upgrades to 2.3.0 with all settings and funds unchanged and `coldWallet` zero.
- **Size check** in CI for `EPKVault` (fails above 24,476 bytes, i.e. less than 100 bytes headroom).
- **BSC Testnet:** register a cold wallet, try the attacks (E1, E2 cancelled by the Watchtower, E5, E11), then
  evacuate — with saved execution traces, re-checkable with `scripts/v2/verify_evidence.py`, like the demos.

Around it: the Watchtower raises a **COLD WALLET CHANGE** alarm and cancels unexpected changes (like any
unexpected change), and with option C can evacuate on its own when the owner enables it; the SDK gets
`evacuate`, `setColdWallet` and explanations for the new errors.

## 8. Decisions of the owner (2026-11-08)

1. Who may trigger evacuation: **option C** — the admin, the recovery key and an optional evacuator the owner
   sets through the timelock (off by default). Guardians keep their rule: they stop, they never move funds.
2. Cold-wallet change wait in production: **max(3 × delay, 2 days)**, cancellable by any guardian.
3. Evacuation also pauses the vault and revokes policies and sessions, like `panic`: **yes**.

Not part of this item: the fast track for critical security fixes (roadmap item 6b) — a separate design.
