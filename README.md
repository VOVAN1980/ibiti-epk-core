# Eternal Permission Kernel (EPK) — v1 Reference Implementation

![CI](https://github.com/VOVAN1980/ibiti-epk-core/actions/workflows/ci.yml/badge.svg)

EPK is an immutable execution kernel with modular validators and instant revocation.
It enables safe delegated execution for agents without implicit approve(∞).

## What EPK solves
Most agent frameworks still rely on long-lived approvals (approve/permit) or broad delegations.
EPK replaces that with a **Policy** (a capability) that is strictly scoped by:
- agent allowlist
- call allowlist (target + selector)
- per-call native value cap
- TTL / deadline
- optional modular validators (spend limits, threat feeds, etc.)

## Key properties
- **Immutable kernel** (no upgrade hooks)
- **Capability-based delegation** (policyId instead of approvals)
- **Instant revoke** (`setPolicyActive(false)`) and **panic button** (`emergencyNonceBump`)
- **Modular validators** (pluggable safety logic)

## Validator statefulness (v1)
In this v1 reference, `IPolicyValidator.validate(...)` is **NOT** `view`.
Validators may update internal state during validation (e.g., rolling spend windows).

## Signing (EIP-712)
EIP-712 domain:
- name: `Eternal Permission Kernel`
- version: `1`
- includes `chainId` and `verifyingContract`

Typed data:
`Execute(policyId, target, value, dataHash, nonce, deadline)`

## Minimal flow (deploy → policy → execute)
1. Deploy `EPKernel`.
2. Create a Policy (capability):
   - allow one or more agents
   - allow specific calls (target + selector)
   - set TTL/deadline + nonce replay protection
   - attach optional validators (e.g., spend limits)
3. Agent executes `execute(...)` using EIP-712 signature.

## Tests
This repository includes a comprehensive Foundry test suite (202/202 passing).

## License
MIT (see `LICENSE`).
