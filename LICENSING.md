# Licensing

This repository contains components under **two licenses**. This page explains which files are
covered by which license and what that means in practice. The license files themselves are
authoritative: [`LICENSE`](LICENSE) (MIT) and [`LICENSE-EPK`](LICENSE-EPK) (IBITI Labs EPK License 1.0).
If anything here conflicts with them, the license files prevail. This page is an explanation, not
legal advice.

## Rights holder

Volodymyr Podkorytov (IBITI Labs). "IBITI Labs" in the copyright notice of [`LICENSE`](LICENSE)
refers to the same rights holder.

## Which license applies to what

| Component | Paths | License |
|---|---|---|
| **EPK v2** — EPKVault, EPKVaultEmergency, EPKVaultProxy, EPKVaultFactory, EPKRegistry, EPKChains, guard modules (DexGuard, ThreatFeedGuard, CompositeGuard) | `contracts/v2/` | **EPK License** ([`LICENSE-EPK`](LICENSE-EPK)) |
| EPK v2 tests and mocks | `test/v2/` | **EPK License** |
| EPK v2 deployment, demo and verification scripts | `scripts/v2/` | **EPK License** |
| EPK Watchtower (automatic guardian) | `watchtower/` | **EPK License** |
| TypeScript SDK | `sdk/` | **MIT**; the contract bytecode it bundles (DexGuard, ThreatFeedGuard, CompositeGuard) is EPK v2 code under the EPK License — see `sdk/LICENSE` |
| Documentation and the website | `docs/`, `README.md`, other top-level `*.md` | MIT |
| Testnet evidence (addresses, transactions, traces, reports) | `deployments/` | MIT |
| Third-party libraries | `lib/` (e.g. OpenZeppelin Contracts) | their own licenses (OpenZeppelin: MIT) — not relicensed |

Each Solidity file and each Python file of EPK v2 states its license in its `SPDX-License-Identifier`
header (`LicenseRef-IBITI-EPK-1.0`). Two files inside these folders are MIT: `contracts/v2/IPolicyValidator.sol`
(a plain validator interface) and `test/v2/MockTarget.sol` (a test helper).

The EPK License applies from the commit that added [`LICENSE-EPK`](LICENSE-EPK); earlier commits keep the license
they were published with.

## EPK v2 under the IBITI Labs EPK License

The code is public so that anyone can read and audit it, test it and build on it. Protecting real assets
with it requires a commercial license. **The license never turns into an open-source license by itself** —
there is no change date.

### Free, no permission needed

- Read, study and audit the code; independent security reviews and bug bounties are welcome.
- Copy, modify and run it, and build on it, on local chains and **public test networks**.
- **Hackathons**, education, academic and independent research, security research.
- Evaluation inside a company, to decide on a commercial license.
- Share the code or your changes — only under the same license, with the license text, the copyright notice
  and a note of what you changed.
- **Prizes, grants and awards** won with a hackathon, competition or research project built on EPK are
  allowed; they do not make the use commercial by themselves.

All free uses are on test networks and local chains only. **Nothing with real value is free** — not even a
hackathon demo on a main network: if an event requires one, ask the Licensor for written permission.

### Requires a commercial license

- **Production use**: any deployment or operation of EPK v2 or a derivative of it that holds, controls,
  secures, moves or monitors assets of real value — on any main network, in any product or service
  (customer vaults, treasuries, trading bots, wallets, custody, payment automation).
- Offering EPK v2, a derivative or a service built on it to others — for a fee, as part of a commercial
  product, or as a hosted or managed service (including a hosted Watchtower).
- Distributing it under any other license.

The license limits only those who receive the code. It does not limit IBITI Labs: we use, deploy, license
and sell EPK, enter it into hackathons and grant programmes, and take prizes, grants and investment for it.

## Commercial licensing

Contact **info@ibiticoin.com** with:

- your company and project;
- the intended use (networks, expected volume of assets, number of vaults/users);
- whether you need support, monitoring (guardian / co-signer services) or custom modules.

Commercial licenses are granted case by case and in writing by the Licensor.

## Contributions

Contributions to `contracts/v2/`, `test/v2/`, `scripts/v2/` or `watchtower/` are accepted under the EPK
License: by submitting one you confirm that you have the right to do so and that the Licensor may use and
license it under any terms, including commercial licenses (section 6 of [`LICENSE-EPK`](LICENSE-EPK)).
Contributions elsewhere are under MIT.

## Note for hackathons

Hackathon use on test networks is free, explicitly, and prizes and grants won with it are allowed. A
deployment on a main network needs the Licensor's written permission. The EPK License is source-available,
not an OSI-approved open-source license. For an event that requires
an OSI license, the MIT parts — the SDK, the documentation and your own application code — can be
submitted as they are; for anything else, contact the Licensor.
