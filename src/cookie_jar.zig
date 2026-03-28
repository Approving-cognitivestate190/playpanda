const std = @import("std");

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8 = "/",
    expires: ?i64 = null, // Unix timestamp, null = session cookie
    secure: bool = false,
    http_only: bool = false,
};

pub const CookieJar = struct {
    cookies: std.ArrayListUnmanaged(Cookie) = .empty,
    allocator: std.mem.Allocator,
    // Owned by fromJson — null when built manually
    _parsed: ?std.json.Parsed(std.json.Value) = null,
    _json_source: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) CookieJar {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CookieJar) void {
        if (self._parsed) |*p| p.deinit();
        if (self._json_source) |s| self.allocator.free(s);
        self.cookies.deinit(self.allocator);
    }

    pub fn add(self: *CookieJar, cookie: Cookie) !void {
        // Replace existing cookie with same name+domain+path
        for (self.cookies.items) |*existing| {
            if (std.mem.eql(u8, existing.name, cookie.name) and
                std.mem.eql(u8, existing.domain, cookie.domain) and
                std.mem.eql(u8, existing.path, cookie.path))
            {
                existing.* = cookie;
                return;
            }
        }
        try self.cookies.append(self.allocator, cookie);
    }

    /// Build a Cookie header value for the given URL, filtering by domain/path and excluding expired cookies.
    pub fn toCookieHeader(self: *const CookieJar, buf: []u8, url: []const u8, now: i64) ![]const u8 {
        const domain = extractDomain(url);
        const path = extractPath(url);

        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();
        var first = true;

        for (self.cookies.items) |cookie| {
            // Check expiry
            if (cookie.expires) |exp| {
                if (exp <= now) continue;
            }

            // Check domain match
            if (!domainMatches(cookie.domain, domain)) continue;

            // Check path match
            if (!pathMatches(cookie.path, path)) continue;

            if (!first) try w.writeAll("; ");
            try w.writeAll(cookie.name);
            try w.writeByte('=');
            try w.writeAll(cookie.value);
            first = false;
        }

        return stream.getWritten();
    }

    /// Serialize cookies to JSON.
    pub fn toJson(self: *const CookieJar, allocator: std.mem.Allocator) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        const w = buf.writer(allocator);

        try w.writeByte('[');
        for (self.cookies.items, 0..) |cookie, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"name\":");
            try writeJsonString(w, cookie.name);
            try w.writeAll(",\"value\":");
            try writeJsonString(w, cookie.value);
            try w.writeAll(",\"domain\":");
            try writeJsonString(w, cookie.domain);
            try w.writeAll(",\"path\":");
            try writeJsonString(w, cookie.path);
            if (cookie.expires) |exp| {
                try w.writeAll(",\"expires\":");
                try std.fmt.format(w, "{d}", .{exp});
            }
            if (cookie.secure) try w.writeAll(",\"secure\":true");
            if (cookie.http_only) try w.writeAll(",\"httpOnly\":true");
            try w.writeByte('}');
        }
        try w.writeByte(']');

        return try allocator.dupe(u8, buf.items);
    }

    /// Deserialize cookies from JSON.
    pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !CookieJar {
        var jar = CookieJar.init(allocator);

        const json_copy = try allocator.dupe(u8, json_str);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_copy, .{}) catch |err| {
            allocator.free(json_copy);
            return err;
        };

        const arr = switch (parsed.value) {
            .array => |a| a,
            else => {
                parsed.deinit();
                allocator.free(json_copy);
                return jar;
            },
        };

        for (arr.items) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };

            const name = getString(obj, "name") orelse continue;
            const value = getString(obj, "value") orelse continue;
            const domain = getString(obj, "domain") orelse continue;

            try jar.add(.{
                .name = name,
                .value = value,
                .domain = domain,
                .path = getString(obj, "path") orelse "/",
                .expires = getIntSigned(obj, "expires"),
                .secure = getBool(obj, "secure"),
                .http_only = getBool(obj, "httpOnly") or getBool(obj, "http_only"),
            });
        }

        jar._parsed = parsed;
        jar._json_source = json_copy;

        return jar;
    }

    pub fn count(self: *const CookieJar) usize {
        return self.cookies.items.len;
    }
};

/// Check if cookie domain matches request domain.
pub fn domainMatches(cookie_domain: []const u8, request_domain: []const u8) bool {
    if (std.mem.eql(u8, cookie_domain, request_domain)) return true;

    // Leading dot means match subdomains
    if (cookie_domain.len > 0 and cookie_domain[0] == '.') {
        const base = cookie_domain[1..];
        if (std.mem.eql(u8, base, request_domain)) return true;
        if (std.mem.endsWith(u8, request_domain, cookie_domain)) return true;
    }

    return false;
}

/// Check if cookie path matches request path.
pub fn pathMatches(cookie_path: []const u8, request_path: []const u8) bool {
    if (std.mem.startsWith(u8, request_path, cookie_path)) return true;
    return false;
}

/// Extract domain from URL string.
pub fn extractDomain(url: []const u8) []const u8 {
    var s = url;
    if (std.mem.indexOf(u8, s, "://")) |idx| {
        s = s[idx + 3 ..];
    }
    for (s, 0..) |c, i| {
        if (c == '/' or c == ':') return s[0..i];
    }
    return s;
}

/// Extract path from URL string.
pub fn extractPath(url: []const u8) []const u8 {
    var s = url;
    if (std.mem.indexOf(u8, s, "://")) |idx| {
        s = s[idx + 3 ..];
    }
    if (std.mem.indexOf(u8, s, "/")) |idx| {
        const path = s[idx..];
        if (std.mem.indexOf(u8, path, "?")) |qi| {
            return path[0..qi];
        }
        return path;
    }
    return "/";
}

/// Write a JSON string literal with proper escaping.
fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                const hex = "0123456789ABCDEF";
                const buf = [_]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xF] };
                try w.writeAll(&buf);
            },
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

pub fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

pub fn getIntSigned(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

pub fn getBool(obj: std.json.ObjectMap, key: []const u8) bool {
    const val = obj.get(key) orelse return false;
    return switch (val) {
        .bool => |b| b,
        else => false,
    };
}

// ── Tests ──

const testing = std.testing;

test "extractDomain — with scheme" {
    try testing.expectEqualStrings("example.com", extractDomain("https://example.com/path"));
    try testing.expectEqualStrings("example.com", extractDomain("http://example.com"));
    try testing.expectEqualStrings("sub.example.com", extractDomain("https://sub.example.com/a/b"));
}

test "extractDomain — with port" {
    try testing.expectEqualStrings("localhost", extractDomain("http://localhost:8080/test"));
}

test "extractDomain — no scheme" {
    try testing.expectEqualStrings("example.com", extractDomain("example.com/path"));
}

test "extractPath — basic" {
    try testing.expectEqualStrings("/path", extractPath("https://example.com/path"));
    try testing.expectEqualStrings("/a/b/c", extractPath("https://example.com/a/b/c"));
    try testing.expectEqualStrings("/", extractPath("https://example.com"));
}

test "extractPath — strips query string" {
    try testing.expectEqualStrings("/search", extractPath("https://example.com/search?q=test"));
}

test "domainMatches — exact" {
    try testing.expect(domainMatches("example.com", "example.com"));
    try testing.expect(!domainMatches("example.com", "other.com"));
}

test "domainMatches — leading dot matches subdomains" {
    try testing.expect(domainMatches(".example.com", "example.com"));
    try testing.expect(domainMatches(".example.com", "sub.example.com"));
    try testing.expect(!domainMatches(".example.com", "notexample.com"));
}

test "pathMatches — prefix" {
    try testing.expect(pathMatches("/", "/anything"));
    try testing.expect(pathMatches("/api", "/api/v1"));
    try testing.expect(!pathMatches("/api", "/other"));
}

test "CookieJar — add and count" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.add(.{ .name = "a", .value = "1", .domain = "example.com" });
    try jar.add(.{ .name = "b", .value = "2", .domain = "example.com" });
    try testing.expectEqual(@as(usize, 2), jar.count());
}

test "CookieJar — deduplicates by name+domain+path" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.add(.{ .name = "token", .value = "old", .domain = "example.com" });
    try jar.add(.{ .name = "token", .value = "new", .domain = "example.com" });
    try testing.expectEqual(@as(usize, 1), jar.count());
    try testing.expectEqualStrings("new", jar.cookies.items[0].value);
}

test "CookieJar — same name different domains are separate" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.add(.{ .name = "id", .value = "1", .domain = "a.com" });
    try jar.add(.{ .name = "id", .value = "2", .domain = "b.com" });
    try testing.expectEqual(@as(usize, 2), jar.count());
}

test "CookieJar — toCookieHeader filters by domain" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.add(.{ .name = "a", .value = "1", .domain = "example.com" });
    try jar.add(.{ .name = "b", .value = "2", .domain = "other.com" });

    var buf: [1024]u8 = undefined;
    const header = try jar.toCookieHeader(&buf, "https://example.com/", 0);
    try testing.expectEqualStrings("a=1", header);
}

test "CookieJar — toCookieHeader excludes expired" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.add(.{ .name = "fresh", .value = "yes", .domain = "example.com", .expires = 9999999999 });
    try jar.add(.{ .name = "stale", .value = "no", .domain = "example.com", .expires = 1000 });

    var buf: [1024]u8 = undefined;
    const header = try jar.toCookieHeader(&buf, "https://example.com/", 5000);
    try testing.expectEqualStrings("fresh=yes", header);
}

test "CookieJar — toCookieHeader includes session cookies (no expiry)" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.add(.{ .name = "sess", .value = "abc", .domain = "example.com" });

    var buf: [1024]u8 = undefined;
    const header = try jar.toCookieHeader(&buf, "https://example.com/", 9999999999);
    try testing.expectEqualStrings("sess=abc", header);
}

test "CookieJar — JSON round-trip" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.add(.{ .name = "token", .value = "abc123", .domain = ".example.com", .path = "/api", .secure = true });
    try jar.add(.{ .name = "sess", .value = "xyz", .domain = "other.com", .expires = 1700000000 });

    const json = try jar.toJson(testing.allocator);
    defer testing.allocator.free(json);

    var jar2 = try CookieJar.fromJson(testing.allocator, json);
    defer jar2.deinit();

    try testing.expectEqual(jar.count(), jar2.count());
    try testing.expectEqualStrings("token", jar2.cookies.items[0].name);
    try testing.expectEqualStrings("abc123", jar2.cookies.items[0].value);
    try testing.expectEqualStrings(".example.com", jar2.cookies.items[0].domain);
    try testing.expect(jar2.cookies.items[0].secure);
}

test "CookieJar — fromJson with empty array" {
    var jar = try CookieJar.fromJson(testing.allocator, "[]");
    defer jar.deinit();
    try testing.expectEqual(@as(usize, 0), jar.count());
}

test "CookieJar — fromJson with invalid JSON returns empty jar" {
    const result = CookieJar.fromJson(testing.allocator, "not json");
    try testing.expectError(error.SyntaxError, result);
}

test "CookieJar — JSON escapes special characters" {
    var jar = CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.add(.{ .name = "val", .value = "has\"quotes\\and\nnewline", .domain = "example.com" });

    const json = try jar.toJson(testing.allocator);
    defer testing.allocator.free(json);

    // Should be valid JSON
    var jar2 = try CookieJar.fromJson(testing.allocator, json);
    defer jar2.deinit();
    try testing.expectEqual(@as(usize, 1), jar2.count());
}
