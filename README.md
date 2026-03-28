# playpanda

Fetch any webpage as clean, LLM-ready markdown. Single binary, zero config.

![demo](demo.gif)

## Why playpanda?

| | playpanda | Crawl4AI | Firecrawl | Jina Reader |
|---|:---:|:---:|:---:|:---:|
| Single binary | Zig | Python + pip | Node + API key | curl only |
| Zero config | Yes | Nearly | No | Yes |
| Auth built-in | Login + cookies | Hooks/profiles | Dashboard | x-set-cookie |
| Anti-bot | 3-tier auto-escalation | Manual config | Partial | No |
| API key required | No | No | Yes | Freemium |
| Avg speed | 1.8s | ~3s | ~5s | ~2s |
| Avg tokens/page | 2,868 | varies | varies | varies |

## How It Works

playpanda uses a 3-tier fetch engine that automatically escalates until it gets content:

| Tier | Method | Speed | When |
|------|--------|-------|------|
| 1 | HTTP + native Zig HTML-to-markdown | ~150ms | Default for most sites |
| 2 | [Lightpanda](https://lightpanda.io/) headless browser | ~1.5s | When Tier 1 returns empty/broken content |
| 3 | [CloakBrowser](https://github.com/CloakHQ/CloakBrowser) | ~6s | Bot-protected sites (Facebook, LinkedIn, Medium, etc.) |

If a page is blocked or empty, playpanda automatically tries the next tier.

## Install

One-liner (installs binary + all dependencies):

```
curl -fsSL https://raw.githubusercontent.com/ancs21/playpanda/main/scripts/install.sh | sh
```

### From source

Requires [Zig](https://ziglang.org/) 0.15+:

```
git clone https://github.com/ancs21/playpanda.git
cd playpanda
zig build -Doptimize=.ReleaseFast
cp zig-out/bin/playpanda ~/.local/bin/
```

### Dependencies

The installer handles these automatically, or install manually:

- [Lightpanda](https://lightpanda.io/) — headless browser for Tier 2
- Python 3 + `websockets` — Tier 3 stealth browser and cookie harvesting
- Chrome/Chromium — for Tier 3 stealth and login flow

## Usage

### Fetch a page

```
playpanda https://example.com                       # markdown to stdout
playpanda https://example.com > article.md          # save to file
```

### Fetch multiple pages

```
playpanda https://example.com,https://ziglang.org   # multiple URLs, separated by ---
```

### Log in to sites

```
playpanda profile                                   # opens browser, log in, press Enter
```

Cookies are saved to `~/.playpanda/cookies.json` and used automatically on subsequent fetches.

### Upgrade

```
playpanda upgrade
```

## How Cookies Work

1. **`playpanda profile`** opens a browser with CDP enabled. Log in to any site, then press Enter. Cookies are harvested via Chrome DevTools Protocol and saved.

2. **Fetch flow**: Cookies are automatically loaded and matched by domain. Tier 1 uses HTTP cookie headers, Tier 2 injects via `Network.setCookies` over CDP.

## Bot-Protected Sites

These domains automatically use Tier 3 (stealth browser):

facebook.com, instagram.com, linkedin.com, x.com, twitter.com, medium.com, google.com, youtube.com, tiktok.com, reddit.com, substack.com, threads.net, pinterest.com

Other sites start at Tier 1 and escalate if blocked.

## Use with LLMs

```bash
# Pipe to Claude
playpanda https://example.com | claude "Summarize this:"

# Pipe to Ollama
playpanda https://example.com | ollama run llama3 "What are the key points?"

# Save for RAG
playpanda https://docs.example.com > corpus/example.md
```

## Project Structure

```
src/
  main.zig          CLI entry point
  browser.zig       3-tier fetch engine
  html2md.zig       HTML-to-markdown converter (Zig native, no Python)
  cdp_client.zig    WebSocket client for Chrome DevTools Protocol
  cookie_jar.zig    Cookie storage, matching, and serialization
  auth.zig          Login flow and cookie harvesting
scripts/
  fetch_page.py     Tier 3: stealth browser page extraction
  harvest_cookies.py  Cookie harvesting via CDP
  install.sh        One-line installer
  test.sh           Test suite
```

## License

[Apache 2.0](LICENSE)
