# Eternal Permission Kernel (EPK) — v1 Reference Implementation

This repository contains a v1 reference implementation of the EPK standard:
an immutable execution kernel with modular validators and instant revocation.

## Key properties
- Immutable kernel (no business logic)
- Capability-based execution (PolicyId instead of approve(∞))
- Instant revoke + emergencyNonceBump
- Modular validators (may be stateful in this reference)

## IMPORTANT: Validator statefulness (v1 reference)
In this v1 reference, `IPolicyValidator.validate(...)` is NOT `view`.
Validators may update internal state (e.g., rolling spend windows) during validation.
Kernel bubbles validator reverts unchanged.
Security note: validators must be designed so state updates only happen after checks.

## Signing (EIP-712)
Domain:
- name: "Eternal Permission Kernel"
- version: "1"
- chainId + verifyingContract

Typed data:
Execute(policyId, target, value, dataHash, nonce, deadline)

## Running tests
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge test -vv

## Validator Statefulness
В отличие от строгого "view-only" подхода в ERC-4337, EPK v1 разрешает stateful validators (например rolling spend limits).
Kernel вызывает validate ДО external call и доверяет, что валидатор не мутирует состояние при revert.
Это осознанный trade-off для удобства rolling-window без commit-фазы.