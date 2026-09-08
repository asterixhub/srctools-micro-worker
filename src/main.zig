const std = @import("std");
const builtin = @import("builtin");
const cfg = @import("config.zig");
const http = @import("http.zig");
const speedrun = @import("speedrun.zig");
const discord = @import("discord.zig");
const state = @import("state.zig");
const worker = @import("worker.zig");

pub const panic = std.debug.no_panic;

var g_shutdown: ?*std.atomic.Value(bool) = null;

pub fn main() !void {
    var debug_alloc = std.heap.DebugAllocator(.{}){};
    defer if (builtin.mode == .Debug) {
        _ = debug_alloc.deinit();
    };
    const gpa = if (builtin.mode == .Debug)
        debug_alloc.allocator()
    else if (builtin.single_threaded)
        std.heap.page_allocator
    else
        std.heap.smp_allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const config = cfg.load(gpa) catch |e| {
        std.log.err("[Config] Invalid configuration ({s}); exiting.", .{@errorName(e)});
        std.process.exit(1);
    };

    var shutdown = std.atomic.Value(bool).init(false);
    installSignals(&shutdown);

    var client = http.Http.init(gpa, io);
    defer client.deinit();

    var src = speedrun.Client.init(gpa, &client, config.speedrun_api_key, &shutdown);
    defer src.deinit();

    var dsc = discord.Discord.init(&client, config.discord_webhook_url, &shutdown);

    var store = try state.StateStore.init(gpa, io, config.state_file);
    defer store.deinit();

    var w = worker.Worker.init(gpa, &config, &src, &dsc, &store, &shutdown);
    defer w.deinit();

    w.run();
}

fn installSignals(shutdown: *std.atomic.Value(bool)) void {
    if (builtin.os.tag != .windows) {
        g_shutdown = shutdown;
        const H = struct {
            fn on(_: std.posix.SIG) callconv(.c) void {
                if (g_shutdown) |s| s.store(true, .release);
            }
        };
        var act = std.posix.Sigaction{
            .handler = .{ .handler = &H.on },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    }
}
