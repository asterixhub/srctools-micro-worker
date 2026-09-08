const std = @import("std");
const util = @import("util.zig");
const cfg = @import("config.zig");
const types = @import("types.zig");

const FeedKind = cfg.FeedKind;
const RunSummary = types.RunSummary;

const SEEN_CAPACITY = 600;
const MAX_DELIVERY_ATTEMPTS = 6;
const STATE_LIMIT = std.Io.Limit.limited(16 * 1024 * 1024);

const DAY_MS = 24 * 60 * 60 * 1000;

/// A pending delivery handed to the worker. Slices borrow store-owned memory
/// and stay valid until the entry is delivered or pruned.
pub const OutboxView = struct {
    id: i64,
    kind: FeedKind,
    run_id: []const u8,
    run: RunSummary,
    attempts: u32,
};

const Seen = struct { run_id: []u8, seen_at: i64 };
const Incomplete = struct { run_id: []u8, first_seen_at: i64 };

const Feed = struct {
    feed_key: []u8,
    kind: FeedKind,
    primed: bool = false,
    high_water: ?[]u8 = null,
    seen: std.ArrayList(Seen) = .empty,
    incomplete: std.ArrayList(Incomplete) = .empty,
};

const OutboxRec = struct {
    id: i64,
    event_key: []u8,
    kind: FeedKind,
    run_id: []u8,
    run: RunSummary,
    attempts: u32 = 0,
    next_attempt_at: i64 = 0,
    delivered_at: ?i64 = null,
    failed_at: ?i64 = null,
    created_at: i64 = 0,
};

pub const StateStore = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    feeds: std.ArrayList(Feed) = .empty,
    outbox: std.ArrayList(OutboxRec) = .empty,
    next_id: i64 = 1,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !StateStore {
        var self = StateStore{ .gpa = gpa, .io = io, .path = try gpa.dupe(u8, path) };
        self.load() catch |e| {
            std.log.warn("[State] Could not load existing state ({s}); starting fresh.", .{@errorName(e)});
        };
        return self;
    }

    pub fn deinit(self: *StateStore) void {
        for (self.feeds.items) |*feed| freeFeed(self.gpa, feed);
        self.feeds.deinit(self.gpa);
        for (self.outbox.items) |*rec| freeOutbox(self.gpa, rec);
        self.outbox.deinit(self.gpa);
        self.gpa.free(self.path);
    }

    fn load(self: *StateStore) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.path, self.gpa, STATE_LIMIT) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer self.gpa.free(bytes);

        const parsed = std.json.parseFromSlice(types.StateFile, self.gpa, bytes, .{
            .ignore_unknown_fields = true,
        }) catch |e| {
            std.log.warn("[State] Ignoring corrupt state file: {s}", .{@errorName(e)});
            return;
        };
        defer parsed.deinit();

        for (parsed.value.feeds) |fs| {
            var feed = Feed{
                .feed_key = try self.gpa.dupe(u8, fs.feed_key),
                .kind = fs.kind,
                .primed = fs.primed,
                .high_water = if (fs.high_water) |hw| try self.gpa.dupe(u8, hw) else null,
            };
            for (fs.seen) |s| {
                try feed.seen.append(self.gpa, .{ .run_id = try self.gpa.dupe(u8, s.run_id), .seen_at = s.seen_at });
            }
            for (fs.incomplete) |c| {
                try feed.incomplete.append(self.gpa, .{ .run_id = try self.gpa.dupe(u8, c.run_id), .first_seen_at = c.first_seen_at });
            }
            try self.feeds.append(self.gpa, feed);
        }
        for (parsed.value.outbox) |ob| {
            try self.outbox.append(self.gpa, .{
                .id = self.next_id,
                .event_key = try self.gpa.dupe(u8, ob.event_key),
                .kind = ob.kind,
                .run_id = try self.gpa.dupe(u8, ob.run_id),
                .run = try dupeRun(self.gpa, ob.run),
                .attempts = ob.attempts,
                .next_attempt_at = ob.next_attempt_at,
                .delivered_at = ob.delivered_at,
                .failed_at = ob.failed_at,
                .created_at = ob.created_at,
            });
            self.next_id += 1;
        }
        std.log.info("[State] Loaded {d} feed(s), {d} outbox entrie(s).", .{ self.feeds.items.len, self.outbox.items.len });
    }

    /// Port of applyFeedPage: prime on first sight, then enqueue genuinely-new
    /// runs, remember seen ids, advance the high-water mark. Returns the number
    /// of newly enqueued deliveries.
    pub fn applyFeedPage(
        self: *StateStore,
        account_id: []const u8,
        feed_key: []const u8,
        kind: FeedKind,
        runs: []const RunSummary,
    ) !usize {
        const now = util.nowMs();
        const feed = try self.getOrCreateFeed(feed_key, kind);
        const primed = feed.primed;
        const high_water: ?[]const u8 = feed.high_water;
        var inserted: usize = 0;

        for (runs) |run| {
            if (run.run_url == null) {
                try rememberIncomplete(self.gpa, feed, run.id, now);
                continue;
            }
            const already_seen = feedHasSeen(feed, run.id);
            const was_incomplete = feedHasIncomplete(feed, run.id);
            const stamp = watermark(kind, run);
            const older = !was_incomplete and kind != .rejected and stamp != null and
                high_water != null and std.mem.order(u8, stamp.?, high_water.?) == .lt;

            if (primed and !already_seen and !older) {
                const event_key = try std.fmt.allocPrint(self.gpa, "{s}:{s}:{s}", .{ account_id, kind.label(), run.id });
                if (self.outboxHasKey(event_key)) {
                    self.gpa.free(event_key);
                } else {
                    try self.addOutbox(event_key, kind, run, now);
                    inserted += 1;
                }
            }
            try rememberSeen(self.gpa, feed, run.id, now);
            clearIncomplete(self.gpa, feed, run.id);
        }

        var page_high: ?[]const u8 = null;
        for (runs) |run| {
            if (run.run_url == null) continue;
            if (watermark(kind, run)) |w| {
                if (page_high == null or std.mem.order(u8, w, page_high.?) == .gt) page_high = w;
            }
        }
        var next_high: ?[]const u8 = high_water;
        if (page_high) |ph| {
            if (next_high == null or std.mem.order(u8, ph, next_high.?) == .gt) next_high = ph;
        }
        try self.setFeedHighWater(feed, next_high);
        feed.primed = true;
        self.trimSeen(feed);
        try self.persist();
        return inserted;
    }

    pub fn pendingOutbox(self: *StateStore, arena: std.mem.Allocator, limit: usize) ![]OutboxView {
        const now = util.nowMs();
        var out: std.ArrayList(OutboxView) = .empty;
        for (self.outbox.items) |*rec| {
            if (rec.delivered_at != null or rec.failed_at != null) continue;
            if (rec.next_attempt_at > now) continue;
            try out.append(arena, .{ .id = rec.id, .kind = rec.kind, .run_id = rec.run_id, .run = rec.run, .attempts = rec.attempts });
            if (out.items.len >= limit) break;
        }
        return out.toOwnedSlice(arena);
    }

    pub fn markDelivered(self: *StateStore, id: i64) !void {
        if (self.findOutbox(id)) |rec| rec.delivered_at = util.nowMs();
        try self.persist();
    }

    pub fn markDeliveryFailed(self: *StateStore, id: i64, attempts: u32, permanent: bool) !bool {
        const exhausted = permanent or attempts >= MAX_DELIVERY_ATTEMPTS;
        const now = util.nowMs();
        const e: i64 = if (attempts > 0) @as(i64, attempts) - 1 else 0;
        const shift: u6 = @intCast(@min(@as(i64, 30), 2 * e));
        const delay = @min(@as(i64, 15 * 60_000), 5000 * (@as(i64, 1) << shift));
        if (self.findOutbox(id)) |rec| {
            rec.attempts = attempts;
            rec.next_attempt_at = now + delay;
            rec.failed_at = if (exhausted) now else null;
        }
        try self.persist();
        return exhausted;
    }

    pub fn pendingCount(self: *StateStore) usize {
        var n: usize = 0;
        for (self.outbox.items) |rec| {
            if (rec.delivered_at == null and rec.failed_at == null) n += 1;
        }
        return n;
    }

    pub fn failedCount(self: *StateStore) usize {
        var n: usize = 0;
        for (self.outbox.items) |rec| {
            if (rec.failed_at != null) n += 1;
        }
        return n;
    }

    pub fn prune(self: *StateStore) !void {
        const now = util.nowMs();
        const delivered_before = now - 30 * DAY_MS;
        const failed_before = now - 90 * DAY_MS;

        var i: usize = 0;
        while (i < self.outbox.items.len) {
            const rec = &self.outbox.items[i];
            const drop = (rec.delivered_at != null and rec.delivered_at.? < delivered_before) or
                (rec.failed_at != null and rec.failed_at.? < failed_before);
            if (drop) {
                freeOutbox(self.gpa, rec);
                _ = self.outbox.orderedRemove(i);
            } else i += 1;
        }
        for (self.feeds.items) |*feed| {
            var j: usize = 0;
            while (j < feed.incomplete.items.len) {
                if (feed.incomplete.items[j].first_seen_at < failed_before) {
                    self.gpa.free(feed.incomplete.items[j].run_id);
                    _ = feed.incomplete.swapRemove(j);
                } else j += 1;
            }
        }
        try self.persist();
    }

    // --- internal helpers -------------------------------------------------

    fn getFeed(self: *StateStore, feed_key: []const u8) ?*Feed {
        for (self.feeds.items) |*f| {
            if (std.mem.eql(u8, f.feed_key, feed_key)) return f;
        }
        return null;
    }

    fn getOrCreateFeed(self: *StateStore, feed_key: []const u8, kind: FeedKind) !*Feed {
        if (self.getFeed(feed_key)) |f| return f;
        try self.feeds.append(self.gpa, .{ .feed_key = try self.gpa.dupe(u8, feed_key), .kind = kind });
        return &self.feeds.items[self.feeds.items.len - 1];
    }

    fn outboxHasKey(self: *StateStore, event_key: []const u8) bool {
        for (self.outbox.items) |rec| {
            if (std.mem.eql(u8, rec.event_key, event_key)) return true;
        }
        return false;
    }

    fn findOutbox(self: *StateStore, id: i64) ?*OutboxRec {
        for (self.outbox.items) |*rec| {
            if (rec.id == id) return rec;
        }
        return null;
    }

    fn addOutbox(self: *StateStore, event_key: []u8, kind: FeedKind, run: RunSummary, now: i64) !void {
        const rec = OutboxRec{
            .id = self.next_id,
            .event_key = event_key,
            .kind = kind,
            .run_id = try self.gpa.dupe(u8, run.id),
            .run = try dupeRun(self.gpa, run),
            .attempts = 0,
            .next_attempt_at = now,
            .created_at = now,
        };
        self.next_id += 1;
        try self.outbox.append(self.gpa, rec);
    }

    fn setFeedHighWater(self: *StateStore, feed: *Feed, next_high: ?[]const u8) !void {
        if (next_high) |nh| {
            if (feed.high_water) |cur| {
                if (std.mem.eql(u8, cur, nh)) return;
            }
            const owned = try self.gpa.dupe(u8, nh);
            if (feed.high_water) |cur| self.gpa.free(cur);
            feed.high_water = owned;
        } else {
            if (feed.high_water) |cur| self.gpa.free(cur);
            feed.high_water = null;
        }
    }

    fn trimSeen(self: *StateStore, feed: *Feed) void {
        while (feed.seen.items.len > SEEN_CAPACITY) {
            self.gpa.free(feed.seen.items[0].run_id);
            _ = feed.seen.orderedRemove(0);
        }
    }

    fn persist(self: *StateStore) !void {
        var arena_inst = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_inst.deinit();
        const a = arena_inst.allocator();

        const feeds = try a.alloc(types.FeedState, self.feeds.items.len);
        for (self.feeds.items, 0..) |*f, idx| {
            const seen = try a.alloc(types.SeenEntry, f.seen.items.len);
            for (f.seen.items, 0..) |s, k| seen[k] = .{ .run_id = s.run_id, .seen_at = s.seen_at };
            const inc = try a.alloc(types.IncompleteEntry, f.incomplete.items.len);
            for (f.incomplete.items, 0..) |c, k| inc[k] = .{ .run_id = c.run_id, .first_seen_at = c.first_seen_at };
            feeds[idx] = .{
                .feed_key = f.feed_key,
                .kind = f.kind,
                .primed = f.primed,
                .high_water = f.high_water,
                .seen = seen,
                .incomplete = inc,
            };
        }
        const outbox = try a.alloc(types.OutboxEntry, self.outbox.items.len);
        for (self.outbox.items, 0..) |*o, idx| {
            outbox[idx] = .{
                .event_key = o.event_key,
                .kind = o.kind,
                .run_id = o.run_id,
                .run = o.run,
                .attempts = o.attempts,
                .next_attempt_at = o.next_attempt_at,
                .delivered_at = o.delivered_at,
                .failed_at = o.failed_at,
                .created_at = o.created_at,
            };
        }
        const doc = types.StateFile{ .feeds = feeds, .outbox = outbox };
        const json = try std.json.Stringify.valueAlloc(a, doc, .{});
        try writeAtomic(self.io, self.path, json);
    }
};

fn writeAtomic(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var af = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.replace(io);
}

fn feedHasSeen(feed: *Feed, run_id: []const u8) bool {
    for (feed.seen.items) |s| {
        if (std.mem.eql(u8, s.run_id, run_id)) return true;
    }
    return false;
}

fn feedHasIncomplete(feed: *Feed, run_id: []const u8) bool {
    for (feed.incomplete.items) |c| {
        if (std.mem.eql(u8, c.run_id, run_id)) return true;
    }
    return false;
}

fn rememberSeen(gpa: std.mem.Allocator, feed: *Feed, run_id: []const u8, now: i64) !void {
    if (feedHasSeen(feed, run_id)) return;
    try feed.seen.append(gpa, .{ .run_id = try gpa.dupe(u8, run_id), .seen_at = now });
}

fn rememberIncomplete(gpa: std.mem.Allocator, feed: *Feed, run_id: []const u8, now: i64) !void {
    if (feedHasIncomplete(feed, run_id)) return;
    try feed.incomplete.append(gpa, .{ .run_id = try gpa.dupe(u8, run_id), .first_seen_at = now });
}

fn clearIncomplete(gpa: std.mem.Allocator, feed: *Feed, run_id: []const u8) void {
    var i: usize = 0;
    while (i < feed.incomplete.items.len) {
        if (std.mem.eql(u8, feed.incomplete.items[i].run_id, run_id)) {
            gpa.free(feed.incomplete.items[i].run_id);
            _ = feed.incomplete.swapRemove(i);
            return;
        }
        i += 1;
    }
}

fn watermark(kind: FeedKind, run: RunSummary) ?[]const u8 {
    return switch (kind) {
        .new_run => run.submitted,
        .approved => run.verify_date,
        .rejected => null,
    };
}

fn dupeOpt(gpa: std.mem.Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |v| try gpa.dupe(u8, v) else null;
}

fn freeOpt(gpa: std.mem.Allocator, s: ?[]const u8) void {
    if (s) |v| gpa.free(v);
}

fn dupeRun(gpa: std.mem.Allocator, r: RunSummary) !RunSummary {
    return .{
        .id = try gpa.dupe(u8, r.id),
        .run_url = try dupeOpt(gpa, r.run_url),
        .game_id = try dupeOpt(gpa, r.game_id),
        .game_name = try dupeOpt(gpa, r.game_name),
        .category_name = try dupeOpt(gpa, r.category_name),
        .map_name = try dupeOpt(gpa, r.map_name),
        .runner = try gpa.dupe(u8, r.runner),
        .primary_seconds = r.primary_seconds,
        .time_display = try dupeOpt(gpa, r.time_display),
        .submitted = try dupeOpt(gpa, r.submitted),
        .verify_date = try dupeOpt(gpa, r.verify_date),
        .rejection_reason = try dupeOpt(gpa, r.rejection_reason),
    };
}

fn freeRun(gpa: std.mem.Allocator, r: RunSummary) void {
    gpa.free(r.id);
    freeOpt(gpa, r.run_url);
    freeOpt(gpa, r.game_id);
    freeOpt(gpa, r.game_name);
    freeOpt(gpa, r.category_name);
    freeOpt(gpa, r.map_name);
    gpa.free(r.runner);
    freeOpt(gpa, r.time_display);
    freeOpt(gpa, r.submitted);
    freeOpt(gpa, r.verify_date);
    freeOpt(gpa, r.rejection_reason);
}

fn freeFeed(gpa: std.mem.Allocator, feed: *Feed) void {
    gpa.free(feed.feed_key);
    if (feed.high_water) |hw| gpa.free(hw);
    for (feed.seen.items) |s| gpa.free(s.run_id);
    feed.seen.deinit(gpa);
    for (feed.incomplete.items) |c| gpa.free(c.run_id);
    feed.incomplete.deinit(gpa);
}

fn freeOutbox(gpa: std.mem.Allocator, rec: *OutboxRec) void {
    gpa.free(rec.event_key);
    gpa.free(rec.run_id);
    freeRun(gpa, rec.run);
}
