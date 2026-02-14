# Contributing

Thanks for your interest in contributing to EPK.

## Development setup

Requirements:
- Foundry (forge)

Install deps:
```bash
forge install
Running tests
forge test -vv
Optional (coverage):

forge coverage --ir-minimum
Formatting
Run:

forge fmt
Check (CI-style):

forge fmt --check
Pull requests
Keep PRs small and focused.

Include tests for fixes and new behavior.

Do not change core semantics unless explicitly discussed.

Keep Solidity pragmas consistent with the repo’s toolchain (see foundry.toml).

Security
If you find a vulnerability, do not open a public issue.
Report it privately (see SECURITY.md).
