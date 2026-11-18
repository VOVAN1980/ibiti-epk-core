# Fast track for urgent security fixes (roadmap 6b)

Status: **built and tested in the registry (2026-11-18), not deployed yet, not audited.** The vault itself is unchanged.

## The problem

A new EPKVault release becomes usable only after a public window, so that anyone can inspect it first:

- **7 days** on mainnets;
- **5 minutes** on the public test networks (BSC Testnet, opBNB Testnet, Sepolia).

Each vault then opts in through its own upgrade wait, which runs at the same time as the window:

- at least **2 days** on mainnets (`max(2 × the vault's timelock, 2 days)`);
- **5 minutes** on the test networks.

So a release normally reaches a vault after **about 7 days** on mainnet, and after **about 5 minutes** on a test network.

For an urgent security fix, 7 days on mainnet is long. Funds are not exposed in the meantime: the owner or a guardian can pause the vault at once (`panic`), and the owner or recovery key can evacuate everything to the cold wallet registered in advance. But the vault cannot do its normal work until the fix arrives.

## The rule

The release registry gets one more role: an independent **security council**. In production this is a multisig, for example 2 of 3 independent people. Its address is fixed when the registry is created. With no council, there is no fast track.

| Who | What they can do | What they cannot do |
|---|---|---|
| Registry owner (IBITI) | propose a release; revoke a release | skip the public window |
| Security council | make an already-proposed **patch** release usable at once (`fastTrack`); revoke a release instantly | list code; touch any vault |
| Vault owner (admin) | decide whether to upgrade their own vault (`scheduleUpgrade`) | upgrade without their vault's upgrade wait |
| Guardians, recovery key | veto the pending upgrade (`cancel`); `panic` cancels it too | — |

A **patch** has the same major and minor version as the release listed before it. For example, 2.3.1 after 2.3.0 is a patch; 2.4.0 is not and always keeps its full window.

## Resulting times

| | Mainnet | Public test networks |
|---|---|---|
| Normal release | about 7 days (window 7 days, vault wait ≥ 2 days, running together) | about 5 minutes (5 + 5 minutes, running together) |
| Fast-tracked patch | **at least 2 days** (the vault's own wait) | about 5 minutes (the vault's own wait) |

On test networks the fast track changes almost nothing in time, because everything already takes minutes there. Its value is on mainnet.

## Threat model

- **The owner's (IBITI's) key is stolen.**
  - The attacker can propose a release but cannot skip the window. The council revokes it at once.
  - Vault owners have 7 days to notice on mainnet, and they would also have to opt in themselves.
- **The owner's key and two council keys are stolen.**
  - The attacker's "patch" becomes usable at once. Every vault owner must still opt in, and then wait at least 2 days on mainnet.
  - Guardians can veto during that wait, and the Watchtower cancels any upgrade the owner did not plan.
- **The council alone is compromised.**
  - It cannot list code. It can only make a proposed patch usable earlier, or revoke releases.
  - Revoking releases can block upgrades (denial of service), but it cannot move funds.
- **The council's keys are lost.** The fast track is unusable, and releases take the normal path.

## Not covered

- **Vaults keep the registry they were created with.** Registries deployed before this change have no council, so their vaults keep the normal path. The vaults on BSC Testnet and opBNB Testnet, including the demo vaults, keep running as they are.
- **The owner and guardians cannot install a fix within hours on mainnet.** That would mean changing the vault itself, which is at the EIP-170 size limit. It is not planned.

## Tests

`test/v2/EPKRegistry.fastTrack.t.sol` covers:

- only the council can fast-track;
- the owner alone cannot;
- the council cannot list code;
- unlisted, revoked or already active releases are refused;
- minor releases are refused;
- with no council, nobody can fast-track;
- the council can revoke;
- the vault still waits its own 2 days on mainnet rules;
- a guardian can still veto;
- only the vault owner can start the upgrade;
- on a test network the cycle stays about 5 minutes.
