const std = @import("std");
const config = @import("config.zig");
const repl = @import("repl.zig");
const ui = @import("ui.zig");
const build_options = @import("build_options");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var provider_override: ?[]const u8 = null;
    var model_override: ?[]const u8 = null;
    var mode_override: ?[]const u8 = null;
    var session_name: []const u8 = "default";
    var positional = std.ArrayList([]const u8).init(allocator);
    defer positional.deinit();

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--provider") and i + 1 < args.len) {
            i += 1;
            provider_override = args[i];
        } else if (std.mem.eql(u8, a, "--model") and i + 1 < args.len) {
            i += 1;
            model_override = args[i];
        } else if (std.mem.eql(u8, a, "--mode") and i + 1 < args.len) {
            i += 1;
            mode_override = args[i];
        } else if (std.mem.eql(u8, a, "--session") and i + 1 < args.len) {
            i += 1;
            session_name = args[i];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            ui.println("hello - agent CLI");
            ui.println("Usage: hello [prompt] [--provider P] [--model M] [--session NAME]");
            return;
        } else if (std.mem.eql(u8, a, "--version")) {
            ui.println(build_options.version);
            return;
        } else {
            try positional.append(a);
        }
    }

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    var cfg = config.load(allocator, cwd);
    if (provider_override) |p| cfg.provider = p;
    if (model_override) |m| cfg.model = m;
    if (mode_override) |m| cfg.mode = m;

    if (positional.items.len > 0) {
        var prompt_buf = std.ArrayList(u8).init(allocator);
        defer prompt_buf.deinit();
        for (positional.items, 0..) |p, idx| {
            if (idx > 0) try prompt_buf.append(' ');
            try prompt_buf.appendSlice(p);
        }
        try repl.runOneShot(allocator, cfg, cwd, prompt_buf.items);
        return;
    }

    try repl.runRepl(allocator, cfg, cwd, session_name);
}
