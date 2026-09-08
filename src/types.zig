const std = @import("std");
const config = @import("config.zig");

pub const FeedKind = config.FeedKind;

pub const RunSummary = struct {
    id: []const u8,
    run_url: ?[]const u8 = null,
    game_id: ?[]const u8 = null,
    game_name: ?[]const u8 = null,
    category_name: ?[]const u8 = null,
    map_name: ?[]const u8 = null,
    runner: []const u8 = "Unknown runner",
    primary_seconds: ?f64 = null,
    time_display: ?[]const u8 = null,
    submitted: ?[]const u8 = null,
    verify_date: ?[]const u8 = null,
    rejection_reason: ?[]const u8 = null,
};

/// One queued Discord delivery. `event_key` = "{account}:{kind}:{run_id}" and
/// is unique, giving the same at-least-once dedup guarantee as the SQLite outbox.
pub const OutboxEntry = struct {
    event_key: []const u8,
    kind: FeedKind,
    run_id: []const u8,
    run: RunSummary,
    attempts: u32 = 0,
    next_attempt_at: i64 = 0,
    delivered_at: ?i64 = null,
    failed_at: ?i64 = null,
    created_at: i64 = 0,
};

pub const SeenEntry = struct {
    run_id: []const u8,
    seen_at: i64,
};

pub const IncompleteEntry = struct {
    run_id: []const u8,
    first_seen_at: i64,
};

pub const FeedState = struct {
    feed_key: []const u8,
    kind: FeedKind,
    primed: bool = false,
    high_water: ?[]const u8 = null,
    seen: []SeenEntry = &.{},
    incomplete: []IncompleteEntry = &.{},
};

/// Full on-disk document. Written atomically on every mutation.
pub const StateFile = struct {
    feeds: []FeedState = &.{},
    outbox: []OutboxEntry = &.{},
};
