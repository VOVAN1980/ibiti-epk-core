# EPK — Threat Model (v1, with v2 notes)

EPK is a **permission kernel**. It reduces the blast radius of automation by enforcing revocable, scoped capabilities.

## What EPK is designed to prevent

- **Unlimited approvals as the default**: permissions are scoped by policy and can be revoked.
- **Replay of old signed intents**: policy nonce rules + emergency nonce bump.
- **Over-broad automation**: allowlist on `(target, selector)` plus external validator checks.
- **Runaway spending**: spend limits (per-tx and rolling-window) via validator.
- **Slow incident response**: one-switch revoke (`active=false`) stops everything.

## ⚠️ Known limitation: v1 is a shared executor

`createPolicy` is open to anyone, and `execute` makes calls **from the kernel's own address**. Any authority attached to the `EPKernel` address is therefore usable by **every** policy owner, not only by the one who granted it:

- **Never `approve` tokens to `EPKernel`** — any other policy owner can spend that allowance.
- **Never send tokens to `EPKernel`** — any policy owner can transfer them out. Native coins sent to it are stuck.
- **Never grant roles or privileges to `EPKernel`** in other contracts.

v1 is safe for calls where the kernel's address carries no privileges. For custody of real funds use **v2 (`EPKVault`)**: one isolated vault per customer — see [SPEC_v2.md](SPEC_v2.md).

## What EPK does NOT prevent (by design)

- **Owner key compromise** (v1): if the owner signer is stolen, the attacker can create new valid signatures and change the policy (including removing the validator). Mitigate with hardware keys, spend limits and short TTLs. Note that v1 verifies owner signatures with ECDSA only, so the owner cannot be a multisig. **v2 moves this threat into scope**: separate operator/admin/guardian roles, timelocked loosening, vault-wide outflow limits, destination allowlist, optional co-signer, ERC-1271 signers.
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
