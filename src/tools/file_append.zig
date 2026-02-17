//! File Append Tool — append content to the end of a file within workspace.
//!
//! Creates the file if it doesn't exist. Uses workspace path scoping
//! and the same path safety checks as file_edit.

const std = @import("std");
const Tool = @import("root.zig").Tool;
const ToolResult = @import("root.zig").ToolResult;
const parseStringField = @import("shell.zig").parseStringField;
const isPathSafe = @import("file_edit.zig").isPathSafe;

/// Maximum file size to read before appending (10MB).
const MAX_FILE_SIZE: usize = 10 * 1024 * 1024;

/// Append content to the end of a file with workspace path scoping.
pub const FileAppendTool = struct {
    workspace_dir: []const u8,

    const vtable = Tool.VTable{
        .execute = &vtableExecute,
        .name = &vtableName,
        .description = &vtableDesc,
        .parameters_json = &vtableParams,
    };

    pub fn tool(self: *FileAppendTool) Tool {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn vtableExecute(ptr: *anyopaque, allocator: std.mem.Allocator, args_json: []const u8) anyerror!ToolResult {
        const self: *FileAppendTool = @ptrCast(@alignCast(ptr));
        return self.execute(allocator, args_json);
    }

    fn vtableName(_: *anyopaque) []const u8 {
        return "file_append";
    }

    fn vtableDesc(_: *anyopaque) []const u8 {
        return "Append content to the end of a file (creates the file if it doesn't exist)";
    }

    fn vtableParams(_: *anyopaque) []const u8 {
        return 
        \\{"type":"object","properties":{"path":{"type":"string","description":"Relative path to the file within the workspace"},"content":{"type":"string","description":"Content to append to the file"}},"required":["path","content"]}
        ;
    }

    fn execute(self: *FileAppendTool, allocator: std.mem.Allocator, args_json: []const u8) !ToolResult {
        const rel_path = parseStringField(args_json, "path") orelse
            return ToolResult.fail("Missing 'path' parameter");

        const content = parseStringField(args_json, "content") orelse
            return ToolResult.fail("Missing 'content' parameter");

        // Block path traversal
        if (!isPathSafe(rel_path)) {
            return ToolResult.fail("Path not allowed: contains traversal or absolute path");
        }

        // Build full path
        const full_path = try std.fs.path.join(allocator, &.{ self.workspace_dir, rel_path });
        defer allocator.free(full_path);

        // Resolve workspace path
        const ws_resolved = std.fs.cwd().realpathAlloc(allocator, self.workspace_dir) catch {
            return ToolResult.fail("Failed to resolve workspace directory");
        };
        defer allocator.free(ws_resolved);

        // Try to read existing content
        const existing = blk: {
            const resolved = std.fs.cwd().realpathAlloc(allocator, full_path) catch {
                break :blk @as(?[]const u8, null);
            };
            defer allocator.free(resolved);

            if (!std.mem.startsWith(u8, resolved, ws_resolved)) {
                return ToolResult.fail("Resolved path escapes workspace");
            }

            const file = std.fs.openFileAbsolute(resolved, .{}) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Failed to open file: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            const data = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch |err| {
                file.close();
                const msg = try std.fmt.allocPrint(allocator, "Failed to read file: {}", .{err});
                return ToolResult{ .success = false, .output = "", .error_msg = msg };
            };
            file.close();
            break :blk @as(?[]const u8, data);
        };
        defer if (existing) |e| allocator.free(e);

        // Build new content
        const new_contents = if (existing) |e|
            try std.mem.concat(allocator, u8, &.{ e, content })
        else
            try allocator.dupe(u8, content);
        defer allocator.free(new_contents);

        // Write back
        const file_w = std.fs.cwd().createFile(full_path, .{ .truncate = true }) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to create/open file: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };
        defer file_w.close();

        file_w.writeAll(new_contents) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to write file: {}", .{err});
            return ToolResult{ .success = false, .output = "", .error_msg = msg };
        };

        // Verify newly created files are within workspace
        if (existing == null) {
            const new_resolved = std.fs.cwd().realpathAlloc(allocator, full_path) catch {
                std.fs.cwd().deleteFile(full_path) catch {};
                return ToolResult.fail("Failed to verify created file is within workspace");
            };
            defer allocator.free(new_resolved);
            if (!std.mem.startsWith(u8, new_resolved, ws_resolved)) {
                std.fs.cwd().deleteFile(full_path) catch {};
                return ToolResult.fail("Created file escapes workspace");
            }
        }

        const msg = try std.fmt.allocPrint(allocator, "Appended {d} bytes to {s}", .{ content.len, rel_path });
        return ToolResult{ .success = true, .output = msg };
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "FileAppendTool name and description" {
    var fat = FileAppendTool{ .workspace_dir = "/tmp" };
    const t = fat.tool();
    try testing.expectEqualStrings("file_append", t.name());
    try testing.expect(t.description().len > 0);
    try testing.expect(t.parametersJson()[0] == '{');
}

test "FileAppendTool missing path" {
    var fat = FileAppendTool{ .workspace_dir = "/tmp" };
    const result = try fat.execute(testing.allocator, "{\"content\":\"hello\"}");
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Missing 'path' parameter", result.error_msg.?);
}

test "FileAppendTool missing content" {
    var fat = FileAppendTool{ .workspace_dir = "/tmp" };
    const result = try fat.execute(testing.allocator, "{\"path\":\"test.txt\"}");
    try testing.expect(!result.success);
    try testing.expectEqualStrings("Missing 'content' parameter", result.error_msg.?);
}

test "FileAppendTool blocks path traversal" {
    var fat = FileAppendTool{ .workspace_dir = "/tmp/workspace" };
    const result = try fat.execute(testing.allocator, "{\"path\":\"../../etc/evil\",\"content\":\"x\"}");
    try testing.expect(!result.success);
    try testing.expect(std.mem.indexOf(u8, result.error_msg.?, "not allowed") != null);
}

test "FileAppendTool appends to existing file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "log.txt", .data = "line1" });

    const ws_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(ws_path);

    var fat = FileAppendTool{ .workspace_dir = ws_path };
    const result = try fat.execute(testing.allocator, "{\"path\":\"log.txt\",\"content\":\"line2\"}");
    defer if (result.output.len > 0) testing.allocator.free(result.output);
    defer if (result.error_msg) |e| testing.allocator.free(e);

    try testing.expect(result.success);
    try testing.expect(std.mem.indexOf(u8, result.output, "Appended") != null);

    const actual = try tmp_dir.dir.readFileAlloc(testing.allocator, "log.txt", 4096);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("line1line2", actual);
}

test "FileAppendTool creates new file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const ws_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(ws_path);

    var fat = FileAppendTool{ .workspace_dir = ws_path };
    const result = try fat.execute(testing.allocator, "{\"path\":\"new.txt\",\"content\":\"hello\"}");
    defer if (result.output.len > 0) testing.allocator.free(result.output);
    defer if (result.error_msg) |e| testing.allocator.free(e);

    try testing.expect(result.success);

    const actual = try tmp_dir.dir.readFileAlloc(testing.allocator, "new.txt", 4096);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("hello", actual);
}

test "FileAppendTool appends to empty file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "empty.txt", .data = "" });

    const ws_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(ws_path);

    var fat = FileAppendTool{ .workspace_dir = ws_path };
    const result = try fat.execute(testing.allocator, "{\"path\":\"empty.txt\",\"content\":\"data\"}");
    defer if (result.output.len > 0) testing.allocator.free(result.output);
    defer if (result.error_msg) |e| testing.allocator.free(e);

    try testing.expect(result.success);

    const actual = try tmp_dir.dir.readFileAlloc(testing.allocator, "empty.txt", 4096);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("data", actual);
}

test "FileAppendTool multiple appends" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(.{ .sub_path = "multi.txt", .data = "A" });

    const ws_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(ws_path);

    var fat = FileAppendTool{ .workspace_dir = ws_path };

    const r1 = try fat.execute(testing.allocator, "{\"path\":\"multi.txt\",\"content\":\"B\"}");
    defer if (r1.output.len > 0) testing.allocator.free(r1.output);
    defer if (r1.error_msg) |e| testing.allocator.free(e);
    try testing.expect(r1.success);

    const r2 = try fat.execute(testing.allocator, "{\"path\":\"multi.txt\",\"content\":\"C\"}");
    defer if (r2.output.len > 0) testing.allocator.free(r2.output);
    defer if (r2.error_msg) |e| testing.allocator.free(e);
    try testing.expect(r2.success);

    const actual = try tmp_dir.dir.readFileAlloc(testing.allocator, "multi.txt", 4096);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("ABC", actual);
}

test "FileAppendTool schema has required params" {
    var fat = FileAppendTool{ .workspace_dir = "/tmp" };
    const t = fat.tool();
    const schema = t.parametersJson();
    try testing.expect(std.mem.indexOf(u8, schema, "path") != null);
    try testing.expect(std.mem.indexOf(u8, schema, "content") != null);
}
