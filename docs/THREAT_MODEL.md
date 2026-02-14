# EPK v1 — Threat Model

EPK is a **permission kernel**. It reduces the blast radius of automation by enforcing revocable, scoped capabilities.

## What EPK is designed to prevent

- **Unlimited approvals as the default**: permissions are scoped by policy and can be revoked.
- **Replay of old signed intents**: policy nonce rules + emergency nonce bump.
- **Over-broad automation**: allowlist on `(target, selector)` plus external validator checks.
- **Runaway spending**: spend limits (per-tx and rolling-window) via validator.
- **Slow incident response**: one-switch revoke (`active=false`) stops everything.

## What EPK does NOT prevent (by design)

- **Owner key compromise**: if the owner signer is stolen, the attacker can create new valid signatures/policies. Mitigate with multisig, hardware keys, passkeys, MPC, spend limits, and short TTLs.
- **Protocol-level exploits**: EPK can prevent your agent from calling dangerous functions, but it can’t fix a broken external protocol.
- **Bad validator logic**: validators are external code. If you plug in a malicious or buggy validator, it can brick execution or allow risky behavior.

## Assumptions

- Kernel is immutable and minimal; “intelligence” lives in validators.
- Default safe posture is: short TTLs, strict allowlists, limits on value, and fast revoke paths.
- Any external dependency (registries/threat feeds) must be treated as untrusted unless governed.

## Recommended operational controls

- Short policy TTL + short agent TTL.
- Spend limits always on.
- Allowlist selectors narrowly (no `approve`, no arbitrary calls unless required).
- Keep a “break-glass” revoke path in the UI.
- Separate “liquidity/treasury” from “automation hot wallet” when possible.
