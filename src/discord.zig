const std = @import("std");
const util = @import("util.zig");
const http = @import("http.zig");
const cfg = @import("config.zig");
const types = @import("types.zig");

const FeedKind = cfg.FeedKind;
const RunSummary = types.RunSummary;

const MAX_ATTEMPTS = 3;

/// A permanent failure (4xx other than 429, or an unusable run) is never
/// retried; a transient one is rescheduled by the outbox for a later cycle.
pub const DeliveryError = error{ PermanentFailure, TransientFailure };
pub const SendError = DeliveryError || util.Aborted;

pub const Discord = struct {
    http: *http.Http,
    url: []const u8,
    shutdown: *std.atomic.Value(bool),
    prng: std.Random.DefaultPrng,

    pub fn init(client: *http.Http, url: []const u8, shutdown: *std.atomic.Value(bool)) Discord {
        return .{
            .http = client,
            .url = url,
            .shutdown = shutdown,
            .prng = std.Random.DefaultPrng.init(@bitCast(util.nowMs() ^ 0x51ed)),
        };
    }

    pub fn send(self: *Discord, arena: std.mem.Allocator, kind: FeedKind, run: RunSummary) SendError!void {
        const payload = try buildPayload(arena, kind, run);

        var attempt: u32 = 1;
        while (attempt <= MAX_ATTEMPTS) : (attempt += 1) {
            if (self.shutdown.load(.acquire)) return error.Aborted;

            var body: http.Allocating = .init(arena);
            const status: u16 = self.http.postJson(self.url, payload, &body) catch |e| {
                if (self.shutdown.load(.acquire)) return error.Aborted;
                if (attempt == MAX_ATTEMPTS) {
                    std.log.err("[Discord] Could not reach Discord: {s}", .{@errorName(e)});
                    return error.TransientFailure;
                }
                const wait = @min(@as(i64, 8000), @as(i64, 800) * (@as(i64, 1) << @intCast(attempt)));
                try util.sleepMs(wait, self.shutdown);
                continue;
            };

            if (status >= 200 and status < 300) return;

            const retryable = status == 429 or status >= 500;
            if (!retryable) {
                std.log.err("[Discord] Discord rejected the webhook (HTTP {d}).", .{status});
                return error.PermanentFailure;
            }
            if (attempt == MAX_ATTEMPTS) {
                std.log.err("[Discord] Discord failed after retries (HTTP {d}).", .{status});
                return error.TransientFailure;
            }
            const wait: i64 = if (status == 429)
                retryAfterMs(arena, body.written())
            else
                @min(@as(i64, 300_000), @as(i64, 800) * (@as(i64, 1) << @intCast(attempt)));
            try util.sleepMs(@min(@as(i64, 300_000), wait), self.shutdown);
        }
        return error.TransientFailure;
    }
};

/// Parse Discord's `{ "retry_after": <seconds> }`; fall back to 1000 ms.
fn retryAfterMs(arena: std.mem.Allocator, body: []const u8) i64 {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, body, .{}) catch return 1000;
    defer parsed.deinit();
    if (parsed.value == .object) {
        if (util.asNumber(parsed.value.object.get("retry_after"))) |secs| {
            if (std.math.isFinite(secs)) return @intFromFloat(@max(0.0, secs * 1000.0));
        }
    }
    return 1000;
}

/// Port of discord.ts safe(): keep newlines + printable chars, trim, truncate.
fn safe(arena: std.mem.Allocator, value: []const u8, max: usize) ![]u8 {
    return util.cleanText(arena, value, max);
}

/// Build the full webhook JSON payload. Returns error.PermanentFailure for a
/// run with no usable URL, matching buildEmbed's throw in discord.ts.
pub fn buildPayload(arena: std.mem.Allocator, kind: FeedKind, run: RunSummary) SendError![]u8 {
    const run_url = run.run_url orelse return error.PermanentFailure;

    const map_src = run.map_name orelse run.category_name orelse "Unknown map";
    const map = safe(arena, map_src, 1024) catch return error.TransientFailure;
    const runner_src = if (run.runner.len > 0) run.runner else "Unknown runner";
    const runner = safe(arena, runner_src, 1024) catch return error.TransientFailure;
    const exact_time = safe(arena, run.time_display orelse "Unknown time", 1024) catch return error.TransientFailure;
    const compact_time: []const u8 = if (run.primary_seconds) |s|
        (util.compactDuration(arena, s) catch return error.TransientFailure)
    else
        exact_time;

    const title: []const u8 = switch (kind) {
        .new_run => "🏆 New Run",
        .approved => "✅ Run verified",
        .rejected => "❌ Run rejected",
    };
    const color: u32 = switch (kind) {
        .new_run => 0x5865f2,
        .approved => 0x57f287,
        .rejected => 0xed4245,
    };

    var description: []u8 = std.fmt.allocPrint(arena, "{s} in {s} by {s}", .{ map, compact_time, runner }) catch
        return error.TransientFailure;
    if (kind == .rejected) {
        if (run.rejection_reason) |reason| {
            const clean = safe(arena, reason, 1016) catch return error.TransientFailure;
            if (clean.len > 0) {
                description = std.fmt.allocPrint(arena, "{s}\nReason: {s}", .{ description, clean }) catch
                    return error.TransientFailure;
            }
        }
    }

    // Serialize with the JSON stringifier so escaping matches JSON.stringify.
    const Embed = struct {
        title: []const u8,
        url: []const u8,
        description: []const u8,
        color: u32,
    };
    const Payload = struct {
        embeds: []const Embed,
        allowed_mentions: struct { parse: []const []const u8 },
    };
    const payload = Payload{
        .embeds = &.{.{ .title = title, .url = run_url, .description = description, .color = color }},
        .allowed_mentions = .{ .parse = &.{} },
    };

    return std.json.Stringify.valueAlloc(arena, payload, .{}) catch error.TransientFailure;
}
