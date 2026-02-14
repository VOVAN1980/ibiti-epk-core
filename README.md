# Eternal Permission Kernel (EPK) — v1 Reference Implementation

![CI](https://github.com/VOVAN1980/ibiti-epk-core/actions/workflows/ci.yml/badge.svg)

EPK is an **immutable execution kernel** with **capability-based delegation** and **instant revocation**.  
It enables safe delegated execution for agents **without implicit approve(∞)**.

---

## Docs

- [Spec (v1)](docs/SPEC.md)
- [Integration](docs/INTEGRATION.md)
- [Threat model](docs/THREAT_MODEL.md)
- [Testnet deployment + smoke evidence](docs/TESTNET_ADDRESSES.md)
- [Labs (demo + docs mirror)](https://www.ibiticoin.com/ibiti-web/labs/index.html)

---

## What EPK solves

Most agent frameworks still rely on long-lived approvals (approve/permit) or broad delegations.  
EPK replaces that with a **Policy** (capability) strictly scoped by:

- agent allowlist
- call allowlist (**target + selector**)
- per-call native value cap
- TTL / deadline
- optional modular validators (spend limits, threat feeds, etc.)

---

## Key properties

- **Immutable kernel** (no upgrade hooks)
- **Capability-based delegation** (`policyId` instead of approvals)
- **Instant revoke**: `setPolicyActive(false)`
- **Panic button**: `emergencyNonceBump()` invalidates queued signatures
- **Modular validators** (pluggable safety logic)

---

## Minimal flow (policy → execute → revoke)

Goal: show the real “owner signs → agent executes → owner can instantly revoke”.

1) **Create a Policy**
   - allow agents: `setAgent(policyId, agent, true, ttl)`
   - allow calls: `setCall(policyId, target, selector, true)`
   - set caps: `maxValuePerCall`, optional `validUntil`, optional `validator`

2) **Execute**
   - owner signs EIP-712 `Execute(policyId, target, value, dataHash, nonce, deadline)`
   - agent/relayer submits `execute(...)`
   - kernel verifies:
     - policy exists + active
     - agent is allowed (+ TTL)
     - call is allowed (target + selector)
     - nonce matches, deadline fresh
     - optional validator passes
   - kernel performs the call

3) **Revoke**
   - `setPolicyActive(policyId, false)` disables policy instantly
   - `emergencyNonceBump(policyId, newNonce)` kills pending signatures

---

## Validator statefulness (v1)

In this v1 reference, `IPolicyValidator.validate(...)` is **NOT** `view`.  
Validators may update internal state during validation (e.g., rolling spend windows).

---

## Signing (EIP-712)

Domain:
- name: `Eternal Permission Kernel`
- version: `1`
- includes `chainId` and `verifyingContract`

Typed data:
`Execute(policyId, target, value, dataHash, nonce, deadline)`

---

## Quickstart (Foundry)

### Build + tests
```bash
forge build
forge test -vv
forge coverage --ir-minimum --report summary --report lcov
Smoke test on BSC testnet (policy → execute → revoke)
The on-chain evidence (tx hashes + verified contracts) is maintained here:
➡️ docs/TESTNET_ADDRESSES.md

Windows PowerShell (reads RPC from .env, exports vars so vm.env* works):

cd D:\ibiti-epk-core

# export .env -> process env (so vm.envAddress/vm.envUint can read it)
Get-Content .\.env | ForEach-Object {
  if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)\s*$') {
    [Environment]::SetEnvironmentVariable($matches[1], $matches[2].Trim(), "Process")
  }
}

# rpc strictly from .env
$rpc = (Select-String -Path .\.env -Pattern '^BSC_RPC_URL=').Line.Split('=')[1].Trim()

# broadcast
forge script .\scripts\SmokeTest.s.sol:SmokeTest --rpc-url $rpc --broadcast -vvvv
Artifacts produced by Foundry:

broadcast/SmokeTest.s.sol/97/run-latest.json

cache/SmokeTest.s.sol/97/run-latest.json

Testnet deployment (BSC testnet, chainId 97)
Verified contract addresses + deployment tx hashes + smoke-test evidence:
➡️ docs/TESTNET_ADDRESSES.md

Tests & coverage (Feb 2026)
Functional: 202/202 passing (100%)

Line: 94.21% • Statement: 95.11%

Branch: 58.33% (viaIR source-map limitations; may be underreported)

Invariants: 2 passed (nonce monotonicity + revoked policy safety) — 256 runs / 128k calls

Notes:

viaIR + --ir-minimum used to avoid “stack too deep” → branch % can look lower than reality.

Ground truth: 100% functional pass + explicit branch-hit tests.

License
MIT (see LICENSE)

::contentReference[oaicite:0]{index=0}
