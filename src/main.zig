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
    var session_name: []const u8 = "default";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--provider") and i + 1 < args.len) {
            i += 1;
            provider_override = args[i];
        } else if (std.mem.eql(u8, a, "--model") and i + 1 < args.len) {
            i += 1;
            model_override = args[i];
        } else if (std.mem.eql(u8, a, "--session") and i + 1 < args.len) {
            i += 1;
            session_name = args[i];
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            ui.println("hello - agent CLI");
            ui.println("Usage: hello [--provider P] [--model M] [--session NAME]");
            return;
        } else if (std.mem.eql(u8, a, "--version")) {
            ui.println(build_options.version);
            return;
        }
    }

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    var cfg = config.load(allocator, cwd);
    if (provider_override) |p| cfg.provider = p;
    if (model_override) |m| cfg.model = m;

    try repl.runRepl(allocator, cfg, cwd, session_name);
}
