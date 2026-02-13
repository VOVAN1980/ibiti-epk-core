@'
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

| Version | Supported |
|--------:|:---------:|
| v1.x    | ✅        |
| < v1.0  | ❌        |
'@ | Set-Content -Encoding utf8 .\SECURITY.md
