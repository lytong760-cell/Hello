const std = @import("std");
const config = @import("config.zig");
const types = @import("types.zig");
const llm = @import("llm/provider.zig");
const tools = @import("tools/registry.zig");
const session = @import("session.zig");
const skills = @import("skills.zig");
const permissions = @import("permissions.zig");
const ui = @import("ui.zig");

const Agent = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    cwd: []const u8,
    messages: std.ArrayList(types.Message),
    skills_list: []skills.Skill,
    session_path: []const u8,
    tools_json: []const u8,
};

pub fn buildToolsJson(allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    const w = out.writer();
    try w.writeAll("[");
    for (tools.tools, 0..) |t, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{s}}}}}", .{ t.name, t.description, t.parameters_json });
    }
    try w.writeAll("]");
    return out.toOwnedSlice();
}

fn buildSystemPrompt(allocator: std.mem.Allocator, skills_list: []skills.Skill) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    const w = out.writer();
    try w.writeAll("You are Hello, a helpful coding agent CLI. You have tools to read/write/edit files, search, and run shell commands. Be concise. Use tools when needed.\n");
    if (skills_list.len > 0) {
        try w.writeAll("\nAvailable skills:\n");
        for (skills_list) |s| {
            try w.print("- {s}: {s}\n", .{ s.name, s.description });
        }
    }
    return out.toOwnedSlice();
}

fn sessionPath(allocator: std.mem.Allocator, cwd: []const u8, name: []const u8) ![]u8 {
    // prefer project .hello if exists
    const proj = try std.fmt.allocPrint(allocator, "{s}/.hello", .{cwd});
    defer allocator.free(proj);
    std.fs.accessAbsolute(proj, .{}) catch {
        // global
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        const dir = try std.fmt.allocPrint(allocator, "{s}/.local/share/hello/sessions", .{home});
        defer allocator.free(dir);
        std.fs.makeDirAbsolute(dir) catch |e| switch (e) { error.PathAlreadyExists => {}, else => return e };
        return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ dir, name });
    };
    const dir = try std.fmt.allocPrint(allocator, "{s}/sessions", .{proj});
    defer allocator.free(dir);
    std.fs.makeDirAbsolute(dir) catch |e| switch (e) { error.PathAlreadyExists => {}, else => return e };
    return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ dir, name });
}

pub fn runRepl(allocator: std.mem.Allocator, cfg: config.Config, cwd: []const u8, session_name: []const u8) !void {
    var agent = Agent{
        .allocator = allocator,
        .cfg = cfg,
        .cwd = cwd,
        .messages = std.ArrayList(types.Message).init(allocator),
        .skills_list = try skills.loadAll(allocator, cwd),
        .session_path = try sessionPath(allocator, cwd, session_name),
        .tools_json = try buildToolsJson(allocator),
    };
    defer agent.messages.deinit();

    // system message
    const sys = try buildSystemPrompt(allocator, agent.skills_list);
    try agent.messages.append(.{ .role = .system, .content = sys });

    // try load session
    const loaded = session.load(allocator, agent.session_path) catch null;
    if (loaded) |msgs| {
        // append all but system? just append
        for (msgs) |m| try agent.messages.append(m);
        ui.println("Loaded session.");
    }

    const stdin = std.io.getStdIn().reader();
    var line_buf: [65536]u8 = undefined;
    ui.println("Hello CLI. Type /help for commands, /exit to quit.");
    while (true) {
        ui.prompt();
        const line = stdin.readUntilDelimiterOrEof(&line_buf, '\n') catch break;
        const input = if (line) |l| std.mem.trim(u8, l, " \r\n") else break;
        if (input.len == 0) continue;
        if (std.mem.startsWith(u8, input, "/")) {
            // slash command
            if (std.mem.eql(u8, input, "/exit") or std.mem.eql(u8, input, "/quit")) break;
            if (std.mem.eql(u8, input, "/help")) {
                ui.println("/help /clear /model <name> /provider <name> /session <name> /skills /exit");
                continue;
            }
            if (std.mem.eql(u8, input, "/clear")) {
                agent.messages.clearRetainingCapacity();
                const sys2 = try buildSystemPrompt(allocator, agent.skills_list);
                try agent.messages.append(.{ .role = .system, .content = sys2 });
                ui.println("Cleared.");
                continue;
            }
            if (std.mem.startsWith(u8, input, "/model ")) {
                agent.cfg.model = try allocator.dupe(u8, input[7..]);
                ui.println("Model updated.");
                continue;
            }
            if (std.mem.startsWith(u8, input, "/provider ")) {
                agent.cfg.provider = try allocator.dupe(u8, input[10..]);
                ui.println("Provider updated.");
                continue;
            }
            if (std.mem.eql(u8, input, "/skills")) {
                for (agent.skills_list) |s| ui.print(s.name);
                ui.println("");
                continue;
            }
            if (std.mem.startsWith(u8, input, "/session ")) {
                const name = input[9..];
                agent.session_path = try sessionPath(allocator, cwd, name);
                ui.println("Session switched.");
                continue;
            }
            ui.println("Unknown command.");
            continue;
        }

        // agent turn
        try agent.messages.append(.{ .role = .user, .content = try allocator.dupe(u8, input) });
        var turns: usize = 0;
        while (turns < 20) : (turns += 1) {
            const resp = llm.chat(allocator, agent.cfg, agent.messages.items, agent.tools_json) catch |e| {
                ui.print("LLM error: ");
                ui.println(@errorName(e));
                break;
            };
            // append assistant
            try agent.messages.append(.{
                .role = .assistant,
                .content = resp.content,
                .tool_calls = resp.tool_calls,
            });
            if (resp.content) |c| {
                ui.println(c);
            }
            if (resp.tool_calls.len == 0) break;
            // run tools
            for (resp.tool_calls) |tc| {
                var result: []const u8 = undefined;
                if (tools.isDangerous(tc.name)) {
                    const desc = try std.fmt.allocPrint(allocator, "{s}({s})", .{ tc.name, tc.arguments });
                    if (permissions.confirm(allocator, desc)) {
                        result = tools.runTool(allocator, tc.name, tc.arguments) catch |e| try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(e)});
                    } else {
                        result = try allocator.dupe(u8, "Permission denied by user.");
                    }
                } else {
                    result = tools.runTool(allocator, tc.name, tc.arguments) catch |e| try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(e)});
                }
                // print tool result summary
                ui.print("[tool:");
                ui.print(tc.name);
                ui.print("] ");
                // truncate print
                const preview = if (result.len > 200) result[0..200] else result;
                ui.println(preview);
                try agent.messages.append(.{
                    .role = .tool,
                    .content = result,
                    .tool_call_id = tc.id,
                    .name = tc.name,
                });
            }
        }
        // save session
        session.save(allocator, agent.session_path, agent.messages.items) catch {};
    }
    ui.println("Bye.");
}
