const std = @import("std");
const config = @import("config.zig");
const types = @import("types.zig");
const llm = @import("llm/provider.zig");
const tools = @import("tools/registry.zig");

pub fn runSubagent(allocator: std.mem.Allocator, cfg: config.Config, cwd: []const u8, task: []const u8, depth: usize) ![]u8 {
    _ = cwd;
    if (depth >= 1) return allocator.dupe(u8, "max depth reached");
    var messages = std.ArrayList(types.Message).init(allocator);
    defer messages.deinit();
    const sys = try allocator.dupe(u8, "You are a subagent. Complete the task concisely and return a summary.");
    try messages.append(.{ .role = .system, .content = sys });
    try messages.append(.{ .role = .user, .content = try allocator.dupe(u8, task) });

    var tj = std.ArrayList(u8).init(allocator);
    defer tj.deinit();
    const w = tj.writer();
    try w.writeAll("[");
    for (tools.tools, 0..) |t, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{s}}}}}", .{ t.name, t.description, t.parameters_json });
    }
    try w.writeAll("]");
    const tools_json = try tj.toOwnedSlice();

    var turns: usize = 0;
    var final_text: []u8 = try allocator.dupe(u8, "");
    while (turns < 10) : (turns += 1) {
        var dummy: u8 = 0;
        const ctx: *anyopaque = @ptrCast(&dummy);
        const resp = llm.chatStream(allocator, cfg, messages.items, tools_json, null, ctx) catch |e| {
            const msg = try std.fmt.allocPrint(allocator, "Subagent error: {s}", .{@errorName(e)});
            return msg;
        };
        if (resp.content) |c| {
            allocator.free(final_text);
            final_text = try allocator.dupe(u8, c);
        }
        try messages.append(.{ .role = .assistant, .content = resp.content, .tool_calls = resp.tool_calls });
        if (resp.tool_calls.len == 0) break;
        for (resp.tool_calls) |tc| {
            // subagent denies dangerous tools by default
            var result: []u8 = undefined;
            if (tools.isDangerous(tc.name)) {
                result = try allocator.dupe(u8, "Permission denied (subagent).");
            } else {
                result = tools.runTool(allocator, tc.name, tc.arguments) catch |e| try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(e)});
            }
            const capped = if (result.len > 30000) result[0..30000] else result;
            const final_r = if (result.len > 30000) try std.fmt.allocPrint(allocator, "{s}\n... (truncated)", .{capped}) else result;
            try messages.append(.{ .role = .tool, .content = final_r, .tool_call_id = tc.id, .name = tc.name });
        }
    }
    if (final_text.len == 0) final_text = try allocator.dupe(u8, "(no output)");
    return final_text;
}
