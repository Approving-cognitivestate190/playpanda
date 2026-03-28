# Changelog

## [0.0.1] - 2026-03-28

### Added

- 3-tier fetch engine (HTTP + curl, Lightpanda headless, CloakBrowser stealth)
- Auto-escalation through tiers when content is blocked
- Cookie jar with domain/path matching and expiry
- Login flow via CloakBrowser + CDP cookie harvesting
- Cookie import from CloakBrowser session files
- HTML-to-markdown converter (zero dependencies)
- Markdown cleaner for LLM token optimization
- Bot-detection bypass for 14 major platforms
- CDP WebSocket client in pure Zig
- Batch URL fetching
- User-Agent spoofing proxy for Lightpanda
