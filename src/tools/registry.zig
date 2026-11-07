const std = @import("std");
const read = @import("read.zig");
const write = @import("write.zig");
const edit = @import("edit.zig");
const grep = @import("grep.zig");
const glob = @import("glob.zig");
const bash = @import("bash.zig");

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

pub const tools = [_]ToolDef{
    .{ .name = "read", .description = "Read a file with line numbers", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"offset\":{\"type\":\"integer\"},\"limit\":{\"type\":\"integer\"}},\"required\":[\"path\"]}" },
    .{ .name = "write", .description = "Write content to a file", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}" },
    .{ .name = "edit", .description = "Replace old_string with new_string in file", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"old_string\":{\"type\":\"string\"},\"new_string\":{\"type\":\"string\"}},\"required\":[\"path\",\"old_string\",\"new_string\"]}" },
    .{ .name = "grep", .description = "Search file contents", .parameters_json = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"},\"include\":{\"type\":\"string\"}},\"required\":[\"pattern\"]}" },
    .{ .name = "glob", .description = "Find files by glob pattern", .parameters_json = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"}},\"required\":[\"pattern\"]}" },
    .{ .name = "bash", .description = "Run a shell command", .parameters_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}" },
};

pub fn runTool(allocator: std.mem.Allocator, name: []const u8, args_json: []const u8) ![]u8 {
    if (std.mem.eql(u8, name, "read")) return read.run(allocator, args_json);
    if (std.mem.eql(u8, name, "write")) return write.run(allocator, args_json);
    if (std.mem.eql(u8, name, "edit")) return edit.run(allocator, args_json);
    if (std.mem.eql(u8, name, "grep")) return grep.run(allocator, args_json);
    if (std.mem.eql(u8, name, "glob")) return glob.run(allocator, args_json);
    if (std.mem.eql(u8, name, "bash")) return bash.run(allocator, args_json);
    return error.UnknownTool;
}

pub fn isDangerous(name: []const u8) bool {
    return std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit") or std.mem.eql(u8, name, "bash");
}
