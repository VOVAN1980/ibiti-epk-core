# EPK v1 — Integration Guide

This guide is the “do it once, works everywhere” path to integrate Eternal Permission Kernel (EPK) v1 into an AA wallet, bot, or treasury automation.

## Concepts (10 seconds)

- **Owner**: the signer who defines and revokes permissions (policies).
- **Agent**: a relayer/bot/executor that can call `execute()` **only** within allowed policies.
- **Policy**: a revocable capability: who can act, until when, on which calls, and under which validator.

## Minimal integration flow

### 1) Deploy

Deploy `EPKernel.sol` and required validators (or your own `IPolicyValidator`).

### 2) Create / configure a policy (owner-side)

Typical setup:
1. Create a `policyId` for an `owner`.
2. Set `active=true`.
3. Set `validUntil` (TTL) if you want expiry.
4. Attach a validator contract (SpendLimit / allowlists / threat feeds / custom).

### 3) Allow an agent (owner-side)

- Add `agent` with `agentValidUntil` (TTL).
- Remove / disable agent by setting TTL to 0 or expiring it.

### 4) Allow the calls (owner-side)

Allow only what you want to be executable:
- `target` + `selector` (function selector)
- optional per-target / per-selector limits enforced in the validator

### 5) Agent executes (agent-side)

The agent prepares an `Execution` payload (calls array) and submits:

- `execute(policyId, execution, signature)` — signature must match the owner for the policy and the EIP-712 domain.

The kernel enforces:
- policy active + TTL
- agent allowed + TTL
- per-call allowlist (target+selector)
- nonce rules
- validator `validate()` must not revert

## Revocation & emergency controls

### Fast revoke (panic)

- Set `policy.active = false` (or equivalent setter).
- Result: all executions under this policy revert immediately.

### Emergency nonce bump (signature invalidation)

Use the kernel’s emergency bump to invalidate any previously signed payloads for a policy (even if they are still within TTL).

## Common failure reasons (what your UI/logs should surface)

- Policy inactive / expired (`validUntil`)
- Agent not allowed / expired (`agentValidUntil`)
- Call not allowed (target+selector)
- Nonce mismatch (replay / out-of-order)
- Validator revert (limit exceeded / threat blocked / custom rule failed)

## What to ship in your product

- A simple “Policy UI”: create, enable/disable, TTL, agent TTL, allowlist targets/selectors.
- A “Revoke now” button.
- Optional: preset validators (SpendLimit, TargetSelectorGuard, ThreatFeedBlocklist).
