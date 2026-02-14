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

## Minimal flow (deploy → policy → execute)
Goal: show the real 3-step usage.

1) **Deploy** the kernel:
- deploy `EPKernel`

2) **Create a Policy (capability)**:
- allow one or more agents
- allow specific calls (target + selector)
- set `deadline` (TTL) + `nonce` replay protection
- optionally attach validators (e.g., spend limits)

3) **Execute** a call through the kernel:
- agent signs EIP-712 `Execute(...)` for a specific `(policyId, target, value, dataHash, nonce, deadline)`
- relayer submits `execute(...)`
- kernel verifies: policy active + allowlists + nonce/deadline + validators
- kernel performs deterministic call

Revocation:
- `setPolicyActive(false)` to disable a policy instantly
- `emergencyNonceBump()` to invalidate pending signed executes (panic button)

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

## Tests
This repository includes a comprehensive Foundry test suite (202/202 passing).

## License
MIT (see `LICENSE`).
