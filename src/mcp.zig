const std = @import("std");
const config = @import("config.zig");

pub const McpServer = struct {
    name: []const u8,
    command: []const u8,
    args: [][]const u8,
};

pub var servers: []McpServer = &.{};

pub fn init(allocator: std.mem.Allocator, cfg: config.Config) void {
    var list = std.ArrayList(McpServer).init(allocator);
    for (cfg.mcp_servers) |s| {
        list.append(.{ .name = s.name, .command = s.command, .args = s.args }) catch {};
    }
    servers = list.toOwnedSlice() catch servers;
}

pub fn callTool(allocator: std.mem.Allocator, name: []const u8, args_json: []const u8) ![]u8 {
    _ = allocator;
    _ = name;
    _ = args_json;
    return error.McpNotImplemented;
}

pub fn listServers() []McpServer {
    return servers;
}
