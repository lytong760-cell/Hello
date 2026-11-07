const std = @import("std");
const config = @import("config.zig");
const types = @import("types.zig");
const llm = @import("llm/provider.zig");
const tools = @import("tools/registry.zig");
const session = @import("session.zig");
const skills = @import("skills.zig");
const permissions = @import("permissions.zig");
const ui = @import("ui.zig");

const subagent = @import("subagent.zig");
const mcp = @import("mcp.zig");

const Agent = struct {
    allocator: std.mem.Allocator,
    cfg: config.Config,
    cwd: []const u8,
    messages: std.ArrayList(types.Message),
    skills_list: []skills.Skill,
    session_path: []const u8,
    tools_json: []const u8,
    mode: []const u8,
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

fn buildSystemPrompt(allocator: std.mem.Allocator, skills_list: []skills.Skill, mode: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    const w = out.writer();
    const prefix = if (std.mem.eql(u8, mode, "plan"))
        "You are in planning mode. Prefer reading/searching; writes require confirmation.\n"
    else if (std.mem.eql(u8, mode, "debug"))
        "Focus on diagnosing; use bash to reproduce.\n"
    else
        "You are Hello, a helpful coding agent CLI. You have tools to read/write/edit files, search, and run shell commands. Be concise. Use tools when needed.\n";
    try w.writeAll(prefix);
    if (!std.mem.eql(u8, mode, "code")) {
        try w.writeAll("You are Hello, a helpful coding agent CLI. You have tools to read/write/edit files, search, and run shell commands. Be concise. Use tools when needed.\n");
    }
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
        const base = try std.fmt.allocPrint(allocator, "{s}/.local/share/hello", .{home});
        defer allocator.free(base);
        std.fs.makeDirAbsolute(base) catch |e| switch (e) { error.PathAlreadyExists => {}, else => return e };
        const dir = try std.fmt.allocPrint(allocator, "{s}/sessions", .{base});
        defer allocator.free(dir);
        std.fs.makeDirAbsolute(dir) catch |e| switch (e) { error.PathAlreadyExists => {}, else => return e };
        return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ dir, name });
    };
    const dir = try std.fmt.allocPrint(allocator, "{s}/sessions", .{proj});
    defer allocator.free(dir);
    std.fs.makeDirAbsolute(dir) catch |e| switch (e) { error.PathAlreadyExists => {}, else => return e };
    return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ dir, name });
}

fn estimateTokens(messages: []const types.Message) usize {
    var total: usize = 0;
    for (messages) |m| {
        if (m.content) |c| total += c.len;
        for (m.tool_calls) |tc| {
            total += tc.name.len + tc.arguments.len;
        }
    }
    return total / 4;
}

fn compactIfNeeded(allocator: std.mem.Allocator, messages: *std.ArrayList(types.Message), cfg: config.Config) void {
    const budget = cfg.token_budget;
    const est = estimateTokens(messages.items);
    if (est <= budget) return;
    if (est > budget * 2) {
        // drop oldest non-system
        const idx: usize = 1;
        while (idx < messages.items.len and estimateTokens(messages.items) > budget) {
            _ = messages.orderedRemove(idx);
            if (idx >= messages.items.len) break;
        }
        return;
    }
    // summarize oldest half of non-system
    // find start of non-system (1)
    const start: usize = 1;
    if (messages.items.len <= 2) return;
    const non_sys_count = messages.items.len - 1;
    const half = non_sys_count / 2;
    if (half == 0) return;
    // build text of oldest half
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    for (messages.items[start .. start + half]) |m| {
        if (m.content) |c| {
            buf.appendSlice(c) catch {};
            buf.append('\n') catch {};
        }
    }
    const prompt = std.fmt.allocPrint(allocator, "Summarize the following conversation concisely:\n{s}", .{buf.items}) catch return;
    defer allocator.free(prompt);
    var tmp_msgs = std.ArrayList(types.Message).init(allocator);
    defer tmp_msgs.deinit();
    tmp_msgs.append(.{ .role = .user, .content = prompt }) catch return;
    const tools_json = "[]";
    var dummy: u8 = 0;
    const ctx: *anyopaque = @ptrCast(&dummy);
    const resp = llm.chatStream(allocator, cfg, tmp_msgs.items, tools_json, null, ctx) catch {
        // fallback drop
        var i: usize = 0;
        while (i < half) : (i += 1) {
            if (messages.items.len > 1) _ = messages.orderedRemove(1);
        }
        return;
    };
    const summary = resp.content orelse "compacted";
    // remove oldest half
    var i: usize = 0;
    while (i < half) : (i += 1) {
        if (messages.items.len > 1) _ = messages.orderedRemove(1);
    }
    // insert summary as system note at index 1
    const note = std.fmt.allocPrint(allocator, "Summary of earlier conversation:\n{s}", .{summary}) catch return;
    messages.insert(1, .{ .role = .system, .content = note }) catch {};
}

const StreamCtx = struct {};

fn streamToken(ctx: *anyopaque, chunk: []const u8) void {
    _ = ctx;
    ui.print(chunk);
}

fn printToken(ctx: *anyopaque, chunk: []const u8) void {
    _ = ctx;
    ui.print(chunk);
}

pub fn runOneShot(allocator: std.mem.Allocator, cfg: config.Config, cwd: []const u8, prompt: []const u8) !void {
    const sk = try skills.loadAll(allocator, cwd);
    var messages = std.ArrayList(types.Message).init(allocator);
    defer messages.deinit();
    const mode = cfg.mode;
    const sys = try buildSystemPrompt(allocator, sk, mode);
    try messages.append(.{ .role = .system, .content = sys });
    try messages.append(.{ .role = .user, .content = try allocator.dupe(u8, prompt) });
    const tools_json = try buildToolsJson(allocator);
    mcp.init(allocator, cfg);
    var turns: usize = 0;
    while (turns < 20) : (turns += 1) {
        compactIfNeeded(allocator, &messages, cfg);
        var ctx = StreamCtx{};
        const ctx_ptr: *anyopaque = @ptrCast(&ctx);
        const resp = llm.chatStream(allocator, cfg, messages.items, tools_json, streamToken, ctx_ptr) catch |e| {
            ui.print("LLM error: ");
            ui.println(@errorName(e));
            return;
        };
        try messages.append(.{ .role = .assistant, .content = resp.content, .tool_calls = resp.tool_calls });
        if (resp.content != null) ui.println("");
        if (resp.tool_calls.len == 0) break;
        for (resp.tool_calls) |tc| {
            var result: []const u8 = undefined;
            if (tools.isDangerousForMode(tc.name, mode)) {
                const desc = try std.fmt.allocPrint(allocator, "{s}({s})", .{ tc.name, tc.arguments });
                if (permissions.confirm(allocator, desc)) {
                    result = tools.runTool(allocator, tc.name, tc.arguments) catch |e| try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(e)});
                } else {
                    result = try allocator.dupe(u8, "Permission denied by user.");
                }
            } else {
                result = tools.runTool(allocator, tc.name, tc.arguments) catch |e| try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(e)});
            }
            ui.print("[tool:");
            ui.print(tc.name);
            ui.print("] ");
            const preview = if (result.len > 200) result[0..200] else result;
            ui.println(preview);
            const capped = if (result.len > 30000) result[0..30000] else result;
            const final_result = if (result.len > 30000) try std.fmt.allocPrint(allocator, "{s}\n... (truncated)", .{capped}) else result;
            try messages.append(.{ .role = .tool, .content = final_result, .tool_call_id = tc.id, .name = tc.name });
        }
    }
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
        .mode = cfg.mode,
    };
    defer agent.messages.deinit();

    mcp.init(allocator, cfg);

    // system message
    const sys = try buildSystemPrompt(allocator, agent.skills_list, agent.mode);
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
                const sys2 = try buildSystemPrompt(allocator, agent.skills_list, agent.mode);
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
            if (std.mem.startsWith(u8, input, "/mode ")) {
                agent.mode = try allocator.dupe(u8, input[6..]);
                agent.cfg.mode = agent.mode;
                ui.println("Mode updated.");
                continue;
            }
            if (std.mem.startsWith(u8, input, "/task ")) {
                const summary = subagent.runSubagent(allocator, agent.cfg, agent.cwd, input[6..], 0) catch |e| try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(e)});
                ui.println(summary);
                continue;
            }
            if (std.mem.eql(u8, input, "/mcp list")) {
                for (mcp.listServers()) |s| ui.println(s.name);
                if (mcp.listServers().len == 0) ui.println("No MCP servers.");
                continue;
            }
            if (std.mem.eql(u8, input, "/skills")) {
                for (agent.skills_list) |s| ui.print(s.name);
                ui.println("");
                continue;
            }
            if (std.mem.eql(u8, input, "/session list")) {
                // list sessions in same dir as current session_path
                if (std.fs.path.dirname(agent.session_path)) |dir| {
                    var d = std.fs.openDirAbsolute(dir, .{ .iterate = true }) catch {
                        ui.println("No sessions.");
                        continue;
                    };
                    defer d.close();
                    var it = d.iterate();
                    while (it.next() catch null) |e| {
                        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".json")) {
                            ui.println(e.name[0 .. e.name.len - 5]);
                        }
                    }
                }
                continue;
            }
            if (std.mem.startsWith(u8, input, "/session ")) {
                const name = input[9..];
                agent.session_path = try sessionPath(allocator, cwd, name);
                ui.println("Session switched.");
                continue;
            }
            if (std.mem.eql(u8, input, "/connect")) {
                ui.println("Provider:");
                ui.println("1. OpenAI");
                ui.println("2. Anthropic");
                ui.println("3. Google");
                ui.println("4. Kilo Gateway");
                ui.print("choose Provider: ");
                var buf2: [256]u8 = undefined;
                const l1 = stdin.readUntilDelimiterOrEof(&buf2, '\n') catch null;
                const c1 = if (l1) |x| std.mem.trim(u8, x, " \r\n") else "";
                const choice = std.fmt.parseInt(usize, c1, 10) catch 0;
                const prov_name = switch (choice) {
                    1 => "openai",
                    2 => "anthropic",
                    3 => "google",
                    4 => "kilo",
                    else => null,
                };
                if (prov_name == null) { ui.println("Invalid."); continue; }
                const pname = prov_name.?;
                agent.cfg.provider = try allocator.dupe(u8, pname);
                if (std.mem.eql(u8, pname, "kilo")) {
                    if (agent.cfg.base_url_override == null) agent.cfg.base_url_override = "https://api.kilo.ai/api/gateway";
                }
                ui.print("API: ");
                var buf3: [4096]u8 = undefined;
                const l2 = stdin.readUntilDelimiterOrEof(&buf3, '\n') catch null;
                const key = if (l2) |x| std.mem.trim(u8, x, " \r\n") else "";
                if (std.mem.eql(u8, pname, "openai")) agent.cfg.openai_key = try allocator.dupe(u8, key);
                if (std.mem.eql(u8, pname, "anthropic")) agent.cfg.anthropic_key = try allocator.dupe(u8, key);
                if (std.mem.eql(u8, pname, "google")) agent.cfg.google_key = try allocator.dupe(u8, key);
                if (std.mem.eql(u8, pname, "kilo")) agent.cfg.kilo_key = try allocator.dupe(u8, key);
                config.save(allocator, agent.cwd, agent.cfg) catch {};
                ui.println("Connected.");
                continue;
            }
            if (std.mem.eql(u8, input, "/model")) {
                var models = std.ArrayList([]const u8).init(allocator);
                defer models.deinit();
                const prov = agent.cfg.provider;
                if (std.mem.eql(u8, prov, "openai") or std.mem.eql(u8, prov, "kilo")) {
                    const key = if (std.mem.eql(u8, prov, "kilo")) agent.cfg.kilo_key else agent.cfg.openai_key;
                    const base = if (agent.cfg.base_url_override) |b| b else "https://api.openai.com/v1";
                    const url = try std.fmt.allocPrint(allocator, "{s}/models", .{base});
                    defer allocator.free(url);
                    var client = std.http.Client{ .allocator = allocator };
                    defer client.deinit();
                    const uri = try std.Uri.parse(url);
                    var header_buf: [16384]u8 = undefined;
                    var headers: [1]std.http.Header = undefined;
                    var nheaders: usize = 0;
                    if (key) |k| {
                        headers[0] = .{ .name = "Authorization", .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{k}) };
                        nheaders = 1;
                    }
                    var req = try client.open(.GET, uri, .{ .server_header_buffer = &header_buf, .extra_headers = headers[0..nheaders] });
                    defer req.deinit();
                    try req.send();
                    try req.finish();
                    try req.wait();
                    const rb = try req.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
                    defer allocator.free(rb);
                    const parsed = std.json.parseFromSlice(std.json.Value, allocator, rb, .{}) catch null;
                    if (parsed) |p| {
                        defer p.deinit();
                        if (p.value.object.get("data")) |d| {
                            if (d == .array) {
                                for (d.array.items) |it| {
                                    if (it == .object) {
                                        if (it.object.get("id")) |idv| {
                                            if (idv == .string) try models.append(try allocator.dupe(u8, idv.string));
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if (std.mem.eql(u8, prov, "anthropic")) {
                    const list = [_][]const u8{ "claude-3-5-sonnet-20241022", "claude-3-opus-20240229", "claude-3-haiku-20240307" };
                    for (list) |m| try models.append(try allocator.dupe(u8, m));
                } else if (std.mem.eql(u8, prov, "google")) {
                    const list = [_][]const u8{ "gemini-1.5-pro", "gemini-1.5-flash", "gemini-2.0-flash" };
                    for (list) |m| try models.append(try allocator.dupe(u8, m));
                }
                if (models.items.len == 0) { ui.println("No models found."); continue; }
                for (models.items, 0..) |m, idx| ui.print(std.fmt.allocPrint(allocator, "{d}. {s}\n", .{ idx + 1, m }) catch m);
                ui.print("choose Model (number or id): ");
                var bufm: [256]u8 = undefined;
                const lm = stdin.readUntilDelimiterOrEof(&bufm, '\n') catch null;
                const sel = if (lm) |x| std.mem.trim(u8, x, " \r\n") else "";
                var chosen: ?[]const u8 = null;
                const num = std.fmt.parseInt(usize, sel, 10) catch 0;
                if (num > 0 and num <= models.items.len) {
                    chosen = models.items[num - 1];
                } else if (sel.len > 0) {
                    chosen = try allocator.dupe(u8, sel);
                }
                if (chosen) |c| {
                    agent.cfg.model = c;
                    config.save(allocator, agent.cwd, agent.cfg) catch {};
                    ui.println("Model updated.");
                }
                continue;
            }
            ui.println("Unknown command.");
            continue;
        }

        // agent turn
        try agent.messages.append(.{ .role = .user, .content = try allocator.dupe(u8, input) });
        var turns: usize = 0;
        while (turns < 20) : (turns += 1) {
            compactIfNeeded(allocator, &agent.messages, agent.cfg);
            var ctx = StreamCtx{};
            const ctx_ptr: *anyopaque = @ptrCast(&ctx);
            const resp = llm.chatStream(allocator, agent.cfg, agent.messages.items, agent.tools_json, streamToken, ctx_ptr) catch |e| {
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
            if (resp.content != null) ui.println("");
            if (resp.tool_calls.len == 0) break;
            // run tools
            for (resp.tool_calls) |tc| {
                var result: []const u8 = undefined;
                if (tools.isDangerousForMode(tc.name, agent.mode)) {
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
                const capped_r = if (result.len > 30000) result[0..30000] else result;
                const final_r = if (result.len > 30000) try std.fmt.allocPrint(allocator, "{s}\n... (truncated)", .{capped_r}) else result;
                try agent.messages.append(.{
                    .role = .tool,
                    .content = final_r,
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
