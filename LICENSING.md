# Licensing

This repository contains components under **two different licenses**. This page explains which
files are covered by which license and what that means in practice. The license files themselves
are authoritative: [`LICENSE`](LICENSE) (MIT) and [`LICENSE-BUSL-1.1`](LICENSE-BUSL-1.1)
(Business Source License 1.1). If anything here conflicts with them, the license files prevail.
This page is an explanation, not legal advice.

## Rights holder

Volodymyr Podkorytov (IBITI Labs). "IBITI Labs" in the copyright notice of [`LICENSE`](LICENSE)
refers to the same rights holder.

## Which license applies to what

| Component | Paths | License |
|---|---|---|
| TypeScript SDK | `sdk/` | **MIT** ([`LICENSE`](LICENSE)); the guard bytecode it bundles is EPK v2 code (BUSL-1.1), see `sdk/LICENSE` |
| Documentation and the website | `docs/`, `README.md`, other top-level `*.md` | MIT |
| Testnet evidence (addresses, transactions, traces, reports) | `deployments/` | MIT |
| **EPK v2** — EPKVault, EPKVaultProxy, EPKVaultFactory, EPKRegistry, EPKChains, guard modules (DexGuard, ThreatFeedGuard, CompositeGuard) | `contracts/v2/` | **BUSL-1.1** ([`LICENSE-BUSL-1.1`](LICENSE-BUSL-1.1)) |
| EPK v2 tests and mocks | `test/v2/` | **BUSL-1.1** |
| EPK v2 deployment, demo and verification scripts | `scripts/v2/` | **BUSL-1.1** |
| EPK Watchtower (automatic guardian) | `watchtower/` | **BUSL-1.1** |
| Third-party libraries | `lib/` (e.g. OpenZeppelin Contracts) | their own licenses (OpenZeppelin: MIT) — not relicensed |

Each Solidity file, and each Python file of EPK v2, states its license in its `SPDX-License-Identifier` header.
Two files inside the BUSL folders keep their MIT header: `contracts/v2/IPolicyValidator.sol` (a plain validator
interface) and `test/v2/MockTarget.sol` (a test helper).
Everything already published under MIT stays under MIT permanently.

## EPK v2 under the Business Source License 1.1

Parameters (see [`LICENSE-BUSL-1.1`](LICENSE-BUSL-1.1)):

| Parameter | Value |
|---|---|
| Licensor | Volodymyr Podkorytov (IBITI Labs) |
| Licensed Work | EPK v2: the files in `contracts/v2/`, `test/v2/`, `scripts/v2/` and `watchtower/` |
| Additional Use Grant | Deploy and use on public test networks, in hackathons, and for education, research and security review — as long as it does not hold, control or secure assets of real economic value |
| Change Date | 2030-11-06 (or, for any version, the fourth anniversary of its first public release, whichever comes first) |
| Change License | MIT |

### Free, no permission needed

- Read, study and audit the code; independent security reviews are welcome.
- Copy, modify, fork and redistribute it under the same license.
- Non-production use: development, testing, local and public **test networks**.
- Hackathons, education, research, security review.

### Requires a commercial license

- **Production use**: deploying or operating EPK v2 (or a derivative of it) on a main network, or in
  any product or service, where it holds, controls or secures assets of real economic value
  (e.g. customer vaults, treasuries, trading bots, wallets, custody, payment automation).
- Offering EPK v2 or a derivative to third parties as a hosted or managed service.

### On the Change Date

Each version of EPK v2 automatically becomes available under the **MIT License** on its Change Date
(at the latest four years after that version's first public release). New versions may carry a
later Change Date.

## Commercial licensing

Contact **info@ibiticoin.com** with:

- your company and project;
- the intended use (networks, expected volume of assets, number of vaults/users);
- whether you need support, monitoring (guardian / co-signer services) or custom modules.

Commercial licenses are granted case by case and in writing by the Licensor.

## Contributions

Contributions to `contracts/v2/`, `test/v2/`, `scripts/v2/` or `watchtower/` are accepted under BUSL-1.1 with the same
parameters. By submitting a contribution you confirm that you have the right to do so and that
the Licensor may also offer it under commercial licenses. Contributions elsewhere are under MIT.

## Note for hackathons

The Business Source License is a source-available license, not an OSI-approved open-source
license. Hackathon participation is explicitly allowed by the Additional Use Grant; if an event
strictly requires an OSI-approved license, contact the Licensor.
