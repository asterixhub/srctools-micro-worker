const std = @import("std");

pub const Allocating = std.Io.Writer.Allocating;

pub const Http = struct {
    io: std.Io,
    client: std.http.Client,

    pub fn init(alloc: std.mem.Allocator, io: std.Io) Http {
        return .{ .io = io, .client = .{ .allocator = alloc, .io = io } };
    }

    pub fn deinit(self: *Http) void {
        self.client.deinit();
    }

    pub fn getJson(
        self: *Http,
        url: []const u8,
        api_key: ?[]const u8,
        out: *Allocating,
    ) !u16 {
        var extra: [2]std.http.Header = undefined;
        var n: usize = 0;
        extra[n] = .{ .name = "Accept", .value = "application/json" };
        n += 1;
        if (api_key) |key| {
            extra[n] = .{ .name = "X-API-Key", .value = key };
            n += 1;
        }
        const res = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &out.writer,
            .headers = .{ .user_agent = .{ .override = "s" } },
            .extra_headers = extra[0..n],
            .redirect_behavior = .not_allowed,
        });
        return @intFromEnum(res.status);
    }

    pub fn postJson(
        self: *Http,
        url: []const u8,
        body: []const u8,
        out: *Allocating,
    ) !u16 {
        const res = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .response_writer = &out.writer,
            .headers = .{
                .user_agent = .{ .override = "s" },
                .content_type = .{ .override = "application/json" },
            },
            .redirect_behavior = .not_allowed,
        });
        return @intFromEnum(res.status);
    }
};
