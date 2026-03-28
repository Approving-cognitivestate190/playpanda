# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability, please report it privately via [GitHub Security Advisories](https://github.com/ancs21/playpanda/security/advisories/new).

Do **not** open a public issue for security vulnerabilities.

## Security Measures

- **Secret scanning** and **push protection** enabled
- **Dependabot** monitors Python dependencies
- **TruffleHog** scans for leaked secrets in CI
- Cookie files stored at `~/.playpanda/cookies.json` — protect this file

## Known Considerations

- Cookies are stored in plaintext JSON. Protect `~/.playpanda/` directory permissions.
- CDP WebSocket ports (9444, 19222, 19555) are bound to localhost only.
- Tier 3 opens a browser window briefly for bot-protected sites.
