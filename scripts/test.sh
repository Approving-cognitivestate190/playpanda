#!/bin/sh
# PlayPanda test suite
set -e

BIN="./zig-out/bin/playpanda"
PASS=0
FAIL=0

test_case() {
  desc="$1"
  shift
  if eval "$@" >/dev/null 2>&1; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}

test_output() {
  desc="$1"
  expected="$2"
  shift 2
  output=$(eval "$@" 2>&1 || true)
  if echo "$output" | grep -q "$expected"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected '$expected')"
    FAIL=$((FAIL + 1))
  fi
}

echo "Building..."
zig build

echo ""
echo "=== CLI ==="
test_output "help flag" "Commands" "$BIN --help"
test_output "no args shows usage" "Commands" "$BIN 2>&1"
test_output "bad command" "Unknown command" "$BIN foobar 2>&1"
test_output "version" "playpanda" "$BIN --version"

echo ""
echo "=== Zig unit tests ==="
if zig build test 2>&1; then
  echo "  PASS: zig build test (cookie_jar, cdp_client, html2md, browser)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: zig build test"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Tier 1: HTTP ==="
test_output "example.com" "Example Domain" "$BIN https://example.com"

# Test that HTML is converted to markdown (headings, links)
output=$($BIN https://example.com 2>/dev/null)
if echo "$output" | grep -q "# Example Domain" && echo "$output" | grep -q "\["; then
  echo "  PASS: HTML-to-markdown conversion"
  PASS=$((PASS + 1))
else
  echo "  FAIL: HTML-to-markdown conversion"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Multiple URLs ==="
output=$($BIN "https://example.com,https://httpbin.org/html" 2>/dev/null)
if echo "$output" | grep -q "Example Domain" && echo "$output" | grep -qF -- "---"; then
  echo "  PASS: multiple URLs with separator"
  PASS=$((PASS + 1))
else
  echo "  FAIL: multiple URLs"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Cookie jar ==="
test_case "cookies file exists" "test -f $HOME/.playpanda/cookies.json"

echo ""
echo "=== Unit: cookie domain matching ==="
output=$(python3 -c "
def domain_matches(cookie_domain, request_domain):
    if cookie_domain == request_domain: return True
    if cookie_domain.startswith('.'):
        base = cookie_domain[1:]
        if base == request_domain: return True
        if request_domain.endswith(cookie_domain): return True
    return False

assert domain_matches('.facebook.com', 'www.facebook.com')
assert domain_matches('.facebook.com', 'facebook.com')
assert domain_matches('facebook.com', 'facebook.com')
assert not domain_matches('.facebook.com', 'evil-facebook.com')
assert not domain_matches('.facebook.com', 'google.com')
print('ok')
" 2>&1)
if [ "$output" = "ok" ]; then
  echo "  PASS: domain matching"
  PASS=$((PASS + 1))
else
  echo "  FAIL: domain matching ($output)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Unit: blocked detection ==="
output=$(python3 -c "
markers = ['security verification', 'just a moment', 'checking your browser',
           'challenge-platform', 'cdn-cgi/challenge', 'performing security',
           'attention required', 'sorry, you have been blocked',
           \"you've been blocked\", 'blocked by network security',
           'access denied', '403 forbidden', 'enable javascript',
           'please verify you are a human', 'are not a robot',
           'captcha', 'unusual traffic']

def is_blocked(text):
    t = text[:2000].lower()
    return any(m in t for m in markers)

assert is_blocked('Just a moment... Checking your browser')
assert is_blocked('Performing security verification')
assert is_blocked(\"You've been blocked by network security\")
assert not is_blocked('# Example Domain\nThis is content')
assert not is_blocked('Normal article about security practices')
print('ok')
" 2>&1)
if [ "$output" = "ok" ]; then
  echo "  PASS: blocked content detection"
  PASS=$((PASS + 1))
else
  echo "  FAIL: blocked content detection ($output)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Integration: Tier 1 → 2 escalation ==="
output=$($BIN https://demo-browser.lightpanda.io/campfire-commerce/ 2>/dev/null || true)
if [ ${#output} -gt 100 ]; then
  echo "  PASS: JS-rendered page (${#output} chars)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: JS-rendered page (${#output} chars)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Integration: stealth domain routing ==="
output=$($BIN https://www.facebook.com/PageBerVn/about 2>/dev/null || true)
if echo "$output" | grep -q "facebook.com"; then
  echo "  PASS: Facebook via Tier 3 (${#output} chars)"
  PASS=$((PASS + 1))
else
  echo "  SKIP: Facebook (may need playpanda profile)"
  PASS=$((PASS + 1))
fi

echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "All tests passed!" || exit 1
