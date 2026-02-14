# Eternal Permission Kernel (EPK) — v1 Reference Implementation

This repository contains a v1 reference implementation of the Eternal Permission Kernel (EPK):
an immutable execution kernel with modular validators and instant revocation.

EPK is a permission layer for delegated execution:
instead of giving apps/agents approve(∞), owners grant a **Policy** (a capability) scoped by:
- agent allowlist
- call allowlist (target + selector)
- per-call native value cap
- TTL / deadline
- optional modular validators (spend limits, threat feeds, etc.)

## Key properties
- **Immutable kernel** (no business logic)
- **Capability-based execution** (PolicyId instead of approve(∞))
- **Instant revoke** (`setPolicyActive(false)`) + **panic button** (`emergencyNonceBump`)
- **Modular validators** (pluggable safety logic)

## IMPORTANT: Validator statefulness (v1 reference)
In this v1 reference, `IPolicyValidator.validate(...)` is **NOT** `view`.
Validators may update internal state (e.g., rolling spend windows) during validation.

Security note: validators must be designed so state updates only happen after checks.

## Signing (EIP-712)
Domain:
- name: `Eternal Permission Kernel`
- version: `1`
- includes `chainId` and `verifyingContract`

Typed data:
`Execute(policyId, target, value, dataHash, nonce, deadline)`

## Running tests
```bash
forge install
forge test -vv
