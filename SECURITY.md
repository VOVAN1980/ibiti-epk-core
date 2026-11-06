# Security Policy

## Reporting a Vulnerability

Please report security issues privately.

- Email: info@ibiticoin.com
- Subject: [SECURITY] EPK vulnerability report

If you can, include:
- Summary + impact
- Minimal PoC / steps to reproduce
- Affected commit/tag
- Suggested fix (optional)

## Coordinated Disclosure

Please **do not** publicly disclose the issue (GitHub issues, social media, blog posts) until:
- we confirm the fix is available, and
- we agree on a disclosure date.

We will acknowledge your report and coordinate a fix as quickly as possible.

## Supported Versions

| Version | Supported | Notes |
|--------:|:---------:|:------|
| v2 (EPKVault) | 🚧 | Draft, internally reviewed, not independently audited, not deployed. See [docs/SPEC_v2.md](docs/SPEC_v2.md) and [docs/SECURITY_REVIEW_v2.md](docs/SECURITY_REVIEW_v2.md) |
| v1.x (EPKernel) | ✅ | Reference / testnet. **Never grant token allowances to, or send tokens to, `EPKernel`** — see [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) |
| < v1.0 | ❌ | |
