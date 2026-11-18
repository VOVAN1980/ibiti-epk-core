# Fast track for urgent security fixes (roadmap 6b)

Status: **built and tested (2026-11-18) in the release registry and in vault release 2.4.0; not deployed yet, not audited.** The deployed testnet release stays 2.3.0.

## The problem

A new EPKVault release becomes usable only after a public window, so that anyone can inspect it first:

- **7 days** on mainnets;
- **5 minutes** on the public test networks (BSC Testnet, opBNB Testnet, Sepolia).

Each vault then opts in through its own upgrade wait, which runs at the same time as the window:

- at least **2 days** on mainnets (`max(2 × the vault's timelock, 2 days)`);
- **5 minutes** on the test networks.

So a release normally reaches a vault after **about 7 days** on mainnet, and after **about 5 minutes** on a test network.

For an urgent security fix, 7 days on mainnet is far too long. Funds are not exposed in the meantime: the owner or a guardian can pause the vault at once (`panic`), and the owner or recovery key can evacuate everything to the cold wallet registered in advance. But the vault cannot do its normal work until the fix arrives.

## The rule

The release registry gets one more role: a **security council**, a multisig. Its address is fixed when the registry is created. With no council, there is no fast track.

| Who | What they can do | What they cannot do |
|---|---|---|
| Registry owner (IBITI) | propose a release; revoke a release | skip the public window |
| Security council | flag an already-proposed **patch** release as urgent, which makes it usable at once (`fastTrack`); revoke a release instantly | list code; touch any vault |
| Vault owner (admin) | decide whether to upgrade their own vault (`scheduleUpgrade`) | upgrade without their vault's own timelock |
| Guardians, recovery key | veto the pending upgrade (`cancel`); `panic` cancels it too | — |

A **patch** has the same major and minor version as the release listed before it. For example, 2.4.1 after 2.4.0 is a patch; 2.5.0 is not and always keeps its full window.

From vault release **2.4.0**, a vault asks the registry whether a release is flagged urgent (`isUrgent`). For an urgent fix it waits only its **own timelock**, the one it uses for every other change, if that is shorter than the normal upgrade wait:

- at least **1 hour** on mainnets (the shortest timelock a vault may have);
- **5 minutes** on the test networks.

An owner who set a longer timelock keeps it, also for urgent fixes. A registry that predates the fast track has no `isUrgent`, and its vaults simply keep the normal path.

## Resulting times

| | Mainnet | Public test networks |
|---|---|---|
| Normal release | about 7 days (window 7 days, vault wait ≥ 2 days, running together) | about 5 minutes (5 + 5 minutes, running together) |
| Urgent patch flagged by the council | **the vault's own timelock, at least 1 hour** | about 5 minutes |

On test networks the fast track changes almost nothing in time, because everything already takes minutes there. Its value is on mainnet.

## Who holds the council keys (planned)

Nothing in the contracts depends on this: the council is one address, and the multisig behind it decides how many signatures it needs.

- **Public test networks** (audit, hackathon demos): 2 test keys, both must sign.
- **Mainnet**: 3 keys, any 2 sign — 2 held by IBITI's owner and team, 1 by the EPK developers.
- **Rule for both**: the key that proposes releases (registry owner) and the council keys are held by different people or at least on different devices, so no single stolen key or device can both propose code and flag it urgent.

The council's address cannot be changed later, so on mainnet a 2-of-3 multisig is preferred over 2 of 2: one lost key does not end the fast track, and the other two can replace it.

## Threat model

- **The registry owner's (IBITI's) key is stolen.**
  - The attacker can propose a release but cannot skip the window. The council revokes it at once.
  - Vault owners have 7 days to notice on mainnet, and they would also have to opt in themselves.
- **The registry owner's key and two council keys are stolen.**
  - The attacker's "patch" becomes usable at once. Every vault owner must still opt in, and then wait their vault's own timelock — at least 1 hour on mainnet.
  - Guardians can veto during that wait, and the Watchtower cancels any change the owner did not pre-approve.
- **The council alone is compromised.**
  - It cannot list code. It can only make a proposed patch usable earlier, or revoke releases.
  - Revoking releases can block upgrades (denial of service), but it cannot move funds.
- **A vault owner's (admin's) key is stolen.**
  - The thief can schedule an upgrade only to a release in the registry; the 1-hour path applies only to a patch the council flagged. The guardians and the Watchtower can veto as for any other change.
- **The council's keys are lost.** The fast track is unusable, and releases take the normal path.

## Not covered

- **Vaults keep the registry they were created with.** Registries deployed before this change have no council, so their vaults keep the normal path. The vaults on BSC Testnet and opBNB Testnet, including the demo vaults, keep running as they are.
- **Vaults below 2.4.0** still wait their normal 2 days on mainnet for a flagged fix: the shorter wait is part of the vault code.

## Tests

`test/v2/EPKRegistry.fastTrack.t.sol` covers:

- only the council can fast-track;
- the owner alone cannot;
- the council cannot list code;
- unlisted, revoked or already active releases are refused;
- minor releases are refused;
- with no council, nobody can fast-track;
- the council can revoke;
- an urgent fix installs after the vault's own 1-hour timelock on mainnet rules, not earlier;
- a vault with a longer timelock keeps it;
- the same patch without the flag still waits the normal 2 days;
- a vault on a registry without `isUrgent` still upgrades the normal way;
- a guardian can still veto;
- only the vault owner can start the upgrade;
- on a test network the cycle stays about 5 minutes.
