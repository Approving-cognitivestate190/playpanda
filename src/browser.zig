const std = @import("std");
const cdp = @import("cdp_client.zig");
const CookieJar = @import("cookie_jar.zig").CookieJar;
const cookie_jar_mod = @import("cookie_jar.zig");
const html2md = @import("html2md.zig");

// -- 3-tier fetch engine --
// Tier 1: HTTP + curl (cookies via -b header) → html2md.py (~200ms)
// Tier 2: Lightpanda serve + CDP (cookies via Network.setCookies) → LP.getMarkdown (~1.5s)
// Tier 3: CloakBrowser headless (profile cookies + anti-detection) → JS extract (~6s)
//
// Routing:
//   known bot-protected domain → Tier 3
//   otherwise → Tier 1, if empty/broken → Tier 2

// Domains that require real browser (bot detection)
const stealth_domains = [_][]const u8{
    "facebook.com",
    "instagram.com",
    "linkedin.com",
    "x.com",
    "twitter.com",
    "medium.com",
    "google.com",
    "google.co",
    "youtube.com",
    "tiktok.com",
    "reddit.com",
    "substack.com",
    "threads.net",
    "pinterest.com",
};

fn needsStealth(url: []const u8) bool {
    const domain = cookie_jar_mod.extractDomain(url);
    for (stealth_domains) |sd| {
        if (std.mem.endsWith(u8, domain, sd)) return true;
    }
    return false;
}

/// Find the LightPanda binary.
pub fn findBinary(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("LIGHTPANDA_BINARY_PATH")) |p| return try allocator.dupe(u8, p);
    var buf: [512]u8 = undefined;
    if (std.posix.getenv("HOME")) |home| {
        if (std.fmt.bufPrint(&buf, "{s}/.local/bin/lightpanda", .{home})) |hp| {
            if (std.fs.accessAbsolute(hp, .{})) |_| {
                return try allocator.dupe(u8, hp);
            } else |_| {}
        } else |_| {}
    }
    const candidates = [_][]const u8{ "/usr/local/bin/lightpanda", "/opt/lightpanda/lightpanda" };
    for (candidates) |path| {
        std.fs.accessAbsolute(path, .{}) catch continue;
        return try allocator.dupe(u8, path);
    }
    return error.BinaryNotFound;
}

/// Main entry: fetch URL → markdown. Auto-escalates through tiers.
pub fn fetchMarkdown(allocator: std.mem.Allocator, url: []const u8, jar: ?*const CookieJar, wait_ms: u32) ![]const u8 {
    // Tier 3 shortcut: known stealth-required domains
    if (needsStealth(url)) {
        return fetchCloakBrowser(allocator, url, wait_ms);
    }

    // Tier 1: fast HTTP
    if (fetchHttp(allocator, url, jar)) |content| {
        if (content.len > 100 and !isBlocked(content)) return content;
        allocator.free(content);
    } else |_| {}

    // Tier 2: Lightpanda (JS rendering)
    const lp_result = if (jar != null and jar.?.count() > 0)
        fetchLightpandaCdp(allocator, url, jar, wait_ms)
    else
        fetchLightpandaDirect(allocator, url, wait_ms);

    if (lp_result) |content| {
        if (content.len > 100 and !isBlocked(content)) return content;
        allocator.free(content);
    } else |_| {
    }

    // Tier 3: CloakBrowser (real browser)
    return fetchCloakBrowser(allocator, url, wait_ms);
}

/// Detect if content is a bot challenge / security block / empty page.
fn isBlocked(content: []const u8) bool {
    const markers = [_][]const u8{
        "security verification",
        "Cloudflare",
        "captcha",
        "CAPTCHA",
        "Performing security",
        "not a bot",
        "are not a robot",
        "Browser not supported",
        "Please enable JavaScript",
        "please enable javascript",
        "Xin vui lòng nhấp vào",
        "please click here",
        "Just a moment",
        "Checking your browser",
        "Access denied",
        "403 Forbidden",
        "You are being redirected",
        "challenge-platform",
        "cdn-cgi/challenge",
        "Attention Required",
        "Sorry, you have been blocked",
        "been blocked by network security",
        "unusual traffic",
        "please verify you are a human",
    };
    for (markers) |m| {
        if (containsStr(content, m)) return true;
    }
    return false;
}

fn containsStr(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    // Only check first 2000 chars for efficiency
    const check_len = @min(haystack.len, 2000);
    var i: usize = 0;
    while (i + needle.len <= check_len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

// ── Tier 1: HTTP + cookies ──

fn fetchHttp(allocator: std.mem.Allocator, url: []const u8, jar: ?*const CookieJar) ![]const u8 {
    // Build cookie header for this URL
    var cookie_header: []const u8 = "";
    var cookie_alloc: ?[]const u8 = null;
    defer if (cookie_alloc) |c| allocator.free(c);

    if (jar) |j| {
        var cookie_buf: [8192]u8 = undefined;
        const now = std.time.timestamp();
        const header = j.toCookieHeader(&cookie_buf, url, now) catch "";
        if (header.len > 0) {
            cookie_alloc = try allocator.dupe(u8, header);
            cookie_header = cookie_alloc.?;
        }
    }

    // Build curl command
    var args_buf: [20][]const u8 = undefined;
    var argc: usize = 0;

    args_buf[argc] = "curl";
    argc += 1;
    args_buf[argc] = "-sL";
    argc += 1;
    args_buf[argc] = "-H";
    argc += 1;
    args_buf[argc] = "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36";
    argc += 1;
    args_buf[argc] = "-H";
    argc += 1;
    args_buf[argc] = "Accept-Language: en-US,en;q=0.9";
    argc += 1;
    args_buf[argc] = "--max-time";
    argc += 1;
    args_buf[argc] = "10";
    argc += 1;

    // Add cookie header if present
    var cookie_flag: ?[]const u8 = null;
    defer if (cookie_flag) |f| allocator.free(f);
    if (cookie_header.len > 0) {
        cookie_flag = std.fmt.allocPrint(allocator, "Cookie: {s}", .{cookie_header}) catch null;
        if (cookie_flag) |f| {
            args_buf[argc] = "-H";
            argc += 1;
            args_buf[argc] = f;
            argc += 1;
        }
    }

    args_buf[argc] = url;
    argc += 1;

    var child = std.process.Child.init(args_buf[0..argc], allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.stdin_behavior = .Ignore;

    try child.spawn();
    const stdout_pipe = child.stdout.?;
    const html = stdout_pipe.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return error.CommandFailed;
    const term = try child.wait();
    if (term.Exited != 0 or html.len == 0) {
        allocator.free(html);
        return error.CommandFailed;
    }

    // Convert HTML → markdown via python script
    const md = htmlToMd(allocator, html) catch {
        allocator.free(html);
        return error.CommandFailed;
    };
    allocator.free(html);
    return md;
}

fn htmlToMd(allocator: std.mem.Allocator, html_content: []const u8) ![]const u8 {
    return html2md.convert(allocator, html_content);
}

// ── Tier 2: Lightpanda ──

fn fetchLightpandaDirect(allocator: std.mem.Allocator, url: []const u8, wait_ms: u32) ![]const u8 {
    const binary = try findBinary(allocator);
    defer allocator.free(binary);
    const wait_str = try std.fmt.allocPrint(allocator, "{d}", .{wait_ms});
    defer allocator.free(wait_str);

    const args = [_][]const u8{ binary, "fetch", "--dump", "markdown", "--wait-ms", wait_str, url };
    var child = std.process.Child.init(&args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.stdin_behavior = .Ignore;

    try child.spawn();
    const stdout_pipe = child.stdout.?;
    const output = stdout_pipe.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return error.CommandFailed;
    const term = try child.wait();
    if (term.Exited != 0) {
        allocator.free(output);
        return error.CommandFailed;
    }
    return output;
}

fn fetchLightpandaCdp(allocator: std.mem.Allocator, url: []const u8, jar: ?*const CookieJar, wait_ms: u32) ![]const u8 {
    const binary = try findBinary(allocator);
    defer allocator.free(binary);

    const port: u16 = 19222;
    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_str);

    const serve_args = [_][]const u8{ binary, "serve", "--host", "127.0.0.1", "--port", port_str };
    var server = std.process.Child.init(&serve_args, allocator);
    server.stdout_behavior = .Ignore;
    server.stderr_behavior = .Ignore;
    server.stdin_behavior = .Ignore;
    try server.spawn();
    std.Thread.sleep(500 * std.time.ns_per_ms);
    defer {
        _ = server.kill() catch {};
        _ = server.wait() catch {};
    }

    var client = cdp.CdpClient.connect(allocator, "127.0.0.1", port, "/") catch
        return error.ConnectionFailed;
    defer client.close();

    // Create context + target + attach
    var ctx_resp = try client.sendCommand("Target.createBrowserContext", "{}");
    const ctx_id = extractNested(&ctx_resp, allocator, "browserContextId") orelse return error.CommandFailed;
    defer allocator.free(ctx_id);

    const cp = try std.fmt.allocPrint(allocator, "{{\"url\":\"about:blank\",\"browserContextId\":\"{s}\"}}", .{ctx_id});
    defer allocator.free(cp);
    var cr = try client.sendCommand("Target.createTarget", cp);
    const tid = extractNested(&cr, allocator, "targetId") orelse return error.CommandFailed;
    defer allocator.free(tid);

    const ap = try std.fmt.allocPrint(allocator, "{{\"targetId\":\"{s}\",\"flatten\":true}}", .{tid});
    defer allocator.free(ap);
    var ar = try client.sendCommand("Target.attachToTarget", ap);
    const sid = extractNested(&ar, allocator, "sessionId") orelse return error.CommandFailed;
    defer allocator.free(sid);

    // Enable page + network
    var pr = client.sendSessionCommand(sid, "Page.enable", "{}") catch return error.CommandFailed;
    pr.deinit();
    var nr = client.sendSessionCommand(sid, "Network.enable", "{}") catch return error.CommandFailed;
    nr.deinit();

    // Inject cookies
    if (jar) |j| {
        if (j.count() > 0) {
            const ck = try buildSetCookiesParams(allocator, j);
            defer allocator.free(ck);
            var ckr = client.sendSessionCommand(sid, "Network.setCookies", ck) catch return error.CommandFailed;
            ckr.deinit();
        }
    }

    // Navigate (JSON-escape the URL to prevent injection)
    const np = try buildJsonParam(allocator, "url", url);
    defer allocator.free(np);
    var nvr = client.sendSessionCommand(sid, "Page.navigate", np) catch return error.CommandFailed;
    nvr.deinit();

    // Wait for load
    var loaded = false;
    var wc: u32 = 0;
    while (wc < 300 and !loaded) : (wc += 1) {
        var msg = client.readMessage() catch break;
        defer msg.deinit();
        const obj = switch (msg.value) { .object => |o| o, else => continue };
        const mv = obj.get("method") orelse continue;
        const m = switch (mv) { .string => |s| s, else => continue };
        if (std.mem.eql(u8, m, "Page.loadEventFired")) loaded = true;
    }
    const wns: u64 = @as(u64, if (loaded) wait_ms else wait_ms + 2000) * std.time.ns_per_ms;
    std.Thread.sleep(wns);

    // Get markdown
    var mr = try client.sendSessionCommand(sid, "LP.getMarkdown", "{}");
    defer mr.deinit();
    const md = extractString(mr.value, "markdown") orelse return error.CommandFailed;
    return try allocator.dupe(u8, md);
}

// ── Tier 3: CloakBrowser ──

/// Find a script in known locations.
pub fn findScript(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    // 1. ~/.playpanda/scripts/ (installed location)
    if (std.posix.getenv("HOME")) |home| {
        var buf: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{s}/.playpanda/scripts/{s}", .{ home, name })) |p| {
            if (std.fs.accessAbsolute(p, .{})) |_| {
                return try allocator.dupe(u8, p);
            } else |_| {}
        } else |_| {}
    }
    // 2. scripts/ relative to CWD (dev mode)
    {
        var buf: [1024]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "scripts/{s}", .{name})) |p| {
            std.fs.cwd().access(p, .{}) catch return error.BinaryNotFound;
            return try allocator.dupe(u8, p);
        } else |_| {}
    }
    return error.BinaryNotFound;
}

fn fetchCloakBrowser(allocator: std.mem.Allocator, url: []const u8, wait_ms: u32) ![]const u8 {
    const script = findScript(allocator, "fetch_page.py") catch return error.CommandFailed;
    defer allocator.free(script);
    const wait_str = try std.fmt.allocPrint(allocator, "{d}", .{wait_ms});
    defer allocator.free(wait_str);
    const timeout_secs = (wait_ms / 1000) + 30;
    const timeout_str = try std.fmt.allocPrint(allocator, "{d}", .{timeout_secs});
    defer allocator.free(timeout_str);
    const args = [_][]const u8{ "timeout", timeout_str, "python3", script, url, wait_str };
    var child = std.process.Child.init(&args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.stdin_behavior = .Ignore;
    child.spawn() catch return error.CommandFailed;
    const stdout_pipe = child.stdout.?;
    const output = stdout_pipe.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return error.CommandFailed;
    const term = child.wait() catch return error.CommandFailed;
    if (term.Exited != 0) {
        allocator.free(output);
        return error.CommandFailed;
    }
    return output;
}

// ── Helpers ──

fn extractNested(resp: *std.json.Parsed(std.json.Value), allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    defer resp.deinit();
    const obj = switch (resp.value) { .object => |o| o, else => return null };
    const r = switch (obj.get("result") orelse return null) { .object => |o| o, else => return null };
    const v = switch (r.get(key) orelse return null) { .string => |s| s, else => return null };
    return allocator.dupe(u8, v) catch null;
}

fn extractString(data: std.json.Value, key: []const u8) ?[]const u8 {
    const obj = switch (data) { .object => |o| o, else => return null };
    const r = switch (obj.get("result") orelse return null) { .object => |o| o, else => return null };
    return switch (r.get(key) orelse return null) { .string => |s| s, else => null };
}

/// Build a JSON object with a single string key: {"key":"escaped_value"}
fn writeJsonEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
}

fn buildJsonParam(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"");
    try w.writeAll(key);
    try w.writeAll("\":\"");
    try writeJsonEscaped(w, value);
    try w.writeAll("\"}");
    return try buf.toOwnedSlice(allocator);
}

fn buildSetCookiesParams(allocator: std.mem.Allocator, jar: *const CookieJar) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"cookies\":[");
    for (jar.cookies.items, 0..) |c, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":\"");
        try writeJsonEscaped(w, c.name);
        try w.writeAll("\",\"value\":\"");
        try writeJsonEscaped(w, c.value);
        try w.writeAll("\",\"domain\":\"");
        try writeJsonEscaped(w, c.domain);
        try w.writeAll("\",\"path\":\"");
        try writeJsonEscaped(w, c.path);
        try w.writeByte('"');
        if (c.expires) |exp| try std.fmt.format(w, ",\"expires\":{d}", .{exp});
        if (c.secure) try w.writeAll(",\"secure\":true");
        if (c.http_only) try w.writeAll(",\"httpOnly\":true");
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    return try buf.toOwnedSlice(allocator);
}

// ── Tests ──

const testing = std.testing;

test "needsStealth — known domains" {
    try testing.expect(needsStealth("https://facebook.com/post/123"));
    try testing.expect(needsStealth("https://www.instagram.com/p/abc"));
    try testing.expect(needsStealth("https://medium.com/@user/article"));
    try testing.expect(needsStealth("https://x.com/user/status/123"));
    try testing.expect(needsStealth("https://www.reddit.com/r/test"));
    try testing.expect(needsStealth("https://www.linkedin.com/in/user"));
}

test "needsStealth — normal domains" {
    try testing.expect(!needsStealth("https://example.com"));
    try testing.expect(!needsStealth("https://ziglang.org/"));
    try testing.expect(!needsStealth("https://blog.rust-lang.org/"));
    try testing.expect(!needsStealth("https://httpbin.org/html"));
}

test "isBlocked — detects challenge pages" {
    try testing.expect(isBlocked("Just a moment... Checking your browser"));
    try testing.expect(isBlocked("<html>Cloudflare challenge-platform</html>"));
    try testing.expect(isBlocked("Access denied - 403 Forbidden"));
    try testing.expect(isBlocked("Sorry, you have been blocked"));
}

test "isBlocked — normal content passes" {
    try testing.expect(!isBlocked("# Hello World\n\nThis is a normal article with plenty of content to read."));
    try testing.expect(!isBlocked("<html><body><h1>Welcome</h1><p>Normal page content here.</p></body></html>"));
}

test "buildSetCookiesParams — produces valid CDP JSON" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.add(.{ .name = "session", .value = "abc123", .domain = ".example.com", .path = "/", .secure = true });
    try jar.add(.{ .name = "pref", .value = "dark", .domain = "example.com" });

    const params = try buildSetCookiesParams(testing.allocator, &jar);
    defer testing.allocator.free(params);

    // Verify it's valid JSON
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, params, .{});
    defer parsed.deinit();

    const cookies = parsed.value.object.get("cookies").?.array;
    try testing.expectEqual(@as(usize, 2), cookies.items.len);
    try testing.expectEqualStrings("session", cookies.items[0].object.get("name").?.string);
    try testing.expect(cookies.items[0].object.get("secure").?.bool);
}

test "buildJsonParam — escapes values" {
    const param = try buildJsonParam(testing.allocator, "url", "https://example.com/path?q=1");
    defer testing.allocator.free(param);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, param, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("https://example.com/path?q=1", parsed.value.object.get("url").?.string);
}
