const std = @import("std");

pub const FeedKind = enum {
    new_run,
    approved,
    rejected,

    /// Stable label used in event keys, matching the Node worker's FeedKind
    /// string ("newRun" / "approved" / "rejected").
    pub fn label(self: FeedKind) []const u8 {
        return switch (self) {
            .new_run => "newRun",
            .approved => "approved",
            .rejected => "rejected",
        };
    }

    /// The Speedrun.com `status` query value for this feed.
    pub fn status(self: FeedKind) []const u8 {
        return switch (self) {
            .new_run => "new",
            .approved => "verified",
            .rejected => "rejected",
        };
    }
};

pub const AllowedGame = struct { id: []const u8, name: []const u8 };
pub const ALLOWED_GAMES = [_]AllowedGame{
    .{ .id = "o1yj25r1", .name = "Run pro" },
    .{ .id = "268q8o6p", .name = "Bhop pro" },
};

const DISCORD_HOSTS = [_][]const u8{
    "discord.com",
    "discordapp.com",
    "ptb.discord.com",
    "canary.discord.com",
};

pub const Events = struct {
    new_run: bool = false,
    approved: bool = false,
    rejected: bool = false,

    pub fn has(self: Events, kind: FeedKind) bool {
        return switch (kind) {
            .new_run => self.new_run,
            .approved => self.approved,
            .rejected => self.rejected,
        };
    }
    pub fn count(self: Events) usize {
        return @as(usize, @intFromBool(self.new_run)) +
            @intFromBool(self.approved) + @intFromBool(self.rejected);
    }
};

pub const Config = struct {
    discord_webhook_url: []const u8,
    speedrun_api_key: []const u8,
    check_interval_ms: u64,
    events: Events,
    game_ids: []const []const u8,
    state_file: []const u8,
    port: u16,
};

pub const ConfigError = error{
    MissingRequired,
    InvalidControlCharacters,
    InvalidWebhookUrl,
    InvalidInteger,
    UnknownEvent,
    NoEvents,
    DisallowedGame,
    OutOfMemory,
};

const EnvMap = std.process.Environ.Map;

/// The current process's environment, captured by the startup code into the
/// default `Io.Threaded` instance. Works on Windows (PEB) and POSIX (envp),
/// with or without libc.
fn processEnviron() std.process.Environ {
    return if (std.Options.debug_threaded_io) |t| t.environ.process_environ else .empty;
}

fn getEnv(env: *const EnvMap, name: []const u8) ?[]const u8 {
    return env.get(name);
}

fn required(alloc: std.mem.Allocator, env: *const EnvMap, name: []const u8) ![]u8 {
    const raw = getEnv(env, name) orelse {
        std.log.err("{s} is required.", .{name});
        return ConfigError.MissingRequired;
    };
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) {
        std.log.err("{s} is required.", .{name});
        return ConfigError.MissingRequired;
    }
    for (value) |c| {
        if (c < ' ') {
            std.log.err("{s} contains invalid control characters.", .{name});
            return ConfigError.InvalidControlCharacters;
        }
    }
    return alloc.dupe(u8, value);
}

fn integer(raw: ?[]const u8, fallback: i64, min: i64, max: i64) !i64 {
    const s = raw orelse return fallback;
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return fallback;
    const value = std.fmt.parseInt(i64, trimmed, 10) catch {
        std.log.err("Expected an integer from {d} to {d}, received '{s}'.", .{ min, max, trimmed });
        return ConfigError.InvalidInteger;
    };
    if (value < min or value > max) {
        std.log.err("Expected an integer from {d} to {d}, received '{s}'.", .{ min, max, trimmed });
        return ConfigError.InvalidInteger;
    }
    return value;
}

/// Validate a Discord webhook URL the same way config.ts does, using manual
/// parsing so we do not depend on std.Uri quirks. Returns owned normalized URL.
fn discordWebhook(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    // Must be HTTPS.
    const prefix = "https://";
    if (raw.len <= prefix.len or !std.ascii.startsWithIgnoreCase(raw, prefix)) {
        return webhookError();
    }
    const rest = raw[prefix.len..];
    // No query/fragment allowed anywhere.
    if (std.mem.indexOfAny(u8, rest, "?#") != null) return webhookError();

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return webhookError();
    const host = rest[0..slash];
    const path = rest[slash + 1 ..];

    // Reject credentials or an explicit port in the authority.
    if (std.mem.indexOfAny(u8, host, "@:") != null) return webhookError();

    var host_ok = false;
    for (DISCORD_HOSTS) |h| {
        if (std.ascii.eqlIgnoreCase(host, h)) host_ok = true;
    }
    if (!host_ok) return webhookError();

    // Path must be api/.../webhooks/{id}/{token} with nothing after the token.
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(alloc);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |p| {
        if (p.len > 0) try parts.append(alloc, p);
    }
    if (parts.items.len < 1 or !std.mem.eql(u8, parts.items[0], "api")) return webhookError();
    var webhook_index: ?usize = null;
    for (parts.items, 0..) |p, i| {
        if (std.mem.eql(u8, p, "webhooks")) {
            webhook_index = i;
            break;
        }
    }
    const idx = webhook_index orelse return webhookError();
    if (idx < 1 or parts.items.len != idx + 3) return webhookError();

    return alloc.dupe(u8, raw);
}

fn webhookError() ConfigError {
    std.log.err("DISCORD_WEBHOOK_URL must be an HTTPS Discord webhook URL.", .{});
    return ConfigError.InvalidWebhookUrl;
}

fn parseEvents(raw: ?[]const u8) !Events {
    const s = raw orelse "new,verified,rejected";
    const source = if (std.mem.trim(u8, s, " \t\r\n").len == 0) "new,verified,rejected" else s;
    var events: Events = .{};
    var it = std.mem.splitScalar(u8, source, ',');
    while (it.next()) |token| {
        const v = std.mem.trim(u8, token, " \t\r\n");
        if (v.len == 0) continue;
        if (eqlLower(v, "new") or eqlLower(v, "newrun")) {
            events.new_run = true;
        } else if (eqlLower(v, "verified") or eqlLower(v, "approved")) {
            events.approved = true;
        } else if (eqlLower(v, "rejected")) {
            events.rejected = true;
        } else {
            std.log.err("Unknown MONITORED_EVENTS value '{s}'. Use new, verified and/or rejected.", .{v});
            return ConfigError.UnknownEvent;
        }
    }
    if (events.count() == 0) {
        std.log.err("MONITORED_EVENTS must contain at least one event.", .{});
        return ConfigError.NoEvents;
    }
    return events;
}

fn eqlLower(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn parseGameIds(alloc: std.mem.Allocator, raw: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(alloc);

    const s = raw orelse "";
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |token| {
        const v = std.mem.trim(u8, token, " \t\r\n");
        if (v.len == 0) continue;
        var allowed = false;
        for (ALLOWED_GAMES) |g| {
            if (std.mem.eql(u8, v, g.id)) allowed = true;
        }
        if (!allowed) {
            std.log.err(
                "MONITORED_GAME_IDS may only contain Run pro (o1yj25r1) and Bhop pro (268q8o6p). Received '{s}'.",
                .{v},
            );
            return ConfigError.DisallowedGame;
        }
        try list.append(alloc, try alloc.dupe(u8, v));
    }
    if (list.items.len == 0) {
        for (ALLOWED_GAMES) |g| try list.append(alloc, try alloc.dupe(u8, g.id));
    }
    return list.toOwnedSlice(alloc);
}

pub fn load(alloc: std.mem.Allocator) !Config {
    var env = processEnviron().createMap(alloc) catch EnvMap.init(alloc);
    defer env.deinit();

    const webhook_raw = try required(alloc, &env, "DISCORD_WEBHOOK_URL");
    const discord_webhook_url = try discordWebhook(alloc, webhook_raw);

    const interval_raw = getEnv(&env, "CHECK_INTERVAL_SECONDS");
    const interval_s = try integer(interval_raw, 25, 1, 3600);

    const port_raw = getEnv(&env, "PORT");
    const port = try integer(port_raw, 3000, 1, 65535);

    const volume = getEnv(&env, "RAILWAY_VOLUME_MOUNT_PATH");
    const data_dir = blk: {
        if (volume) |v| {
            const trimmed = std.mem.trim(u8, v, " \t\r\n");
            if (trimmed.len > 0) break :blk try alloc.dupe(u8, trimmed);
        }
        break :blk try std.fs.path.join(alloc, &.{ ".", "data" });
    };
    const state_file = try std.fs.path.join(alloc, &.{ data_dir, "srctools-worker-state.json" });

    return .{
        .discord_webhook_url = discord_webhook_url,
        .speedrun_api_key = try required(alloc, &env, "SPEEDRUN_API_KEY"),
        .check_interval_ms = @as(u64, @intCast(interval_s)) * 1000,
        .events = try parseEvents(getEnv(&env, "MONITORED_EVENTS")),
        .game_ids = try parseGameIds(alloc, getEnv(&env, "MONITORED_GAME_IDS")),
        .state_file = state_file,
        .port = @intCast(port),
    };
}

pub fn gameName(id: []const u8) []const u8 {
    for (ALLOWED_GAMES) |g| {
        if (std.mem.eql(u8, id, g.id)) return g.name;
    }
    return id;
}
