# EPK v1.0.0 — the first public release (archive)

EPK v1 (EPKernel, one shared permission kernel for all users) was the first public release of the project,
published on 2026-02-14. EPK v2 — one vault per customer — replaced it. v1 is not part of the current
product and is kept here only as history.

- Code: branch [`archive/v1`](https://github.com/VOVAN1980/ibiti-epk-core/tree/archive/v1) and tag [`v1.0.0`](https://github.com/VOVAN1980/ibiti-epk-core/tree/v1.0.0). Both stay in git
  unchanged.
- The archived code keeps the license it was published with.
- Its GitHub release was removed from the Releases page on 2026-11-09 (the tag stays). This is the release text
  as it was published:

---

EPK v1.0.0 (reference implementation)

- Immutable permission kernel for delegated execution (policy-as-capability)
- Call allowlists (target + selector), TTL/deadline, replay protection (nonce)
- Instant revocation: `setPolicyActive(false)` + `emergencyNonceBump`
- Modular validators (spend limits, target/selector guards, threat feeds)
- Foundry tests: 202/202 passing

Status: unaudited (v1 reference). Use at your own risk.
