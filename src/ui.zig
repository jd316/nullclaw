//! nullclaw companion UI manager.
//!
//! Handles install/update/run for the `nullclaw-chat-ui` GitHub release
//! artifacts and launches the Node-based UI runner.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");

const log = std.log.scoped(.ui);

const repo_owner = "nullclaw";
const repo_name = "nullclaw-chat-ui";
const package_dir_name = "nullclaw-chat-ui";
const current_version_filename = "current_version";
const node_min_major: u32 = 20;

pub const UpdateOptions = struct {
    check_only: bool = false,
    yes: bool = false,
};

pub const ReleaseInfo = struct {
    tag_name: []const u8,
    html_url: []const u8,
    published_at: []const u8,
    body: []const u8,

    pub fn deinit(self: *const ReleaseInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.tag_name);
        allocator.free(self.html_url);
        allocator.free(self.published_at);
        allocator.free(self.body);
    }
};

pub fn runInstall(allocator: std.mem.Allocator) !void {
    const latest = try getLatestRelease(allocator);
    defer latest.deinit(allocator);

    try installRelease(allocator, latest.tag_name, latest.html_url);
}

pub fn runUpdate(allocator: std.mem.Allocator, opts: UpdateOptions) !void {
    const latest = try getLatestRelease(allocator);
    defer latest.deinit(allocator);

    const base_dir = try uiBaseDir(allocator);
    defer allocator.free(base_dir);

    const installed_tag_opt = try readCurrentVersion(allocator, base_dir);
    defer if (installed_tag_opt) |tag| allocator.free(tag);

    if (installed_tag_opt) |installed_tag| {
        if (std.mem.eql(u8, stripV(installed_tag), stripV(latest.tag_name))) {
            std.debug.print("nullclaw-chat-ui is already up to date: {s}\n", .{installed_tag});
            return;
        }
    }

    std.debug.print("Installed UI: {s}\n", .{if (installed_tag_opt) |tag| tag else "none"});
    std.debug.print("Latest UI:    {s}\n", .{latest.tag_name});
    std.debug.print("Release URL:  {s}\n", .{latest.html_url});

    if (opts.check_only) return;

    if (!opts.yes) {
        std.debug.print("Download and install {s}? [y/N] ", .{latest.tag_name});
        const response = try readLine(allocator);
        defer allocator.free(response);
        if (!std.mem.eql(u8, response, "y") and !std.mem.eql(u8, response, "Y")) {
            std.debug.print("UI update cancelled.\n", .{});
            return;
        }
    }

    try installRelease(allocator, latest.tag_name, latest.html_url);
}

pub fn runRun(allocator: std.mem.Allocator, run_args: []const []const u8) !void {
    const package_dir = try ensureInstalledPackageDir(allocator);
    defer allocator.free(package_dir);

    try ensureNodeRuntime(allocator);

    const script_path = try std.fs.path.join(allocator, &.{ package_dir, "bin", "nullclaw-chat-ui.js" });
    defer allocator.free(script_path);

    if (!pathExists(script_path)) {
        std.debug.print("Installed UI is missing launcher script: {s}\n", .{script_path});
        return error.InvalidArchiveLayout;
    }

    try runUiProcess(allocator, script_path, run_args);
}

pub fn runPath(allocator: std.mem.Allocator) !void {
    const active_path_opt = try resolveActivePackageDir(allocator);
    defer if (active_path_opt) |p| allocator.free(p);

    if (active_path_opt) |path| {
        std.debug.print("{s}\n", .{path});
        return;
    }

    const base_dir = try uiBaseDir(allocator);
    defer allocator.free(base_dir);
    std.debug.print("No installed nullclaw-chat-ui release found.\nBase directory: {s}\n", .{base_dir});
}

fn ensureInstalledPackageDir(allocator: std.mem.Allocator) ![]u8 {
    if (try resolveActivePackageDir(allocator)) |path| {
        return path;
    }

    std.debug.print("No installed nullclaw-chat-ui release found. Installing latest...\n", .{});
    try runInstall(allocator);

    if (try resolveActivePackageDir(allocator)) |path| {
        return path;
    }

    return error.NotInstalled;
}

fn installRelease(allocator: std.mem.Allocator, tag: []const u8, html_url: []const u8) !void {
    const base_dir = try uiBaseDir(allocator);
    defer allocator.free(base_dir);
    try ensureDirAbsolute(base_dir);

    const versions_dir = try versionsDir(allocator, base_dir);
    defer allocator.free(versions_dir);
    try ensureDirAbsolute(versions_dir);

    const package_dir = try packageDirForTag(allocator, base_dir, tag);
    defer allocator.free(package_dir);
    const entry_path = try std.fs.path.join(allocator, &.{ package_dir, "bin", "nullclaw-chat-ui.js" });
    defer allocator.free(entry_path);

    if (pathExists(entry_path)) {
        try writeCurrentVersion(allocator, base_dir, tag);
        std.debug.print("Using already-installed nullclaw-chat-ui {s}\n", .{tag});
        return;
    }

    const version_dir = try versionDirForTag(allocator, base_dir, tag);
    defer allocator.free(version_dir);

    if (pathExists(version_dir)) {
        std.fs.deleteTreeAbsolute(version_dir) catch {};
    }
    try ensureDirAbsolute(version_dir);

    const asset_name = try assetNameForTag(allocator, tag);
    defer allocator.free(asset_name);
    const download_url = try downloadUrlForTag(allocator, tag);
    defer allocator.free(download_url);
    const archive_path = try std.fs.path.join(allocator, &.{ base_dir, asset_name });
    defer allocator.free(archive_path);

    std.debug.print("Downloading {s}...\n", .{asset_name});
    const bytes_downloaded = try downloadToPath(allocator, download_url, archive_path);
    if (bytes_downloaded == 0) return error.EmptyDownload;
    std.debug.print("Downloaded {d} bytes\n", .{bytes_downloaded});
    defer std.fs.deleteFileAbsolute(archive_path) catch {};

    try extractArchive(allocator, archive_path, version_dir);

    if (!pathExists(entry_path)) {
        std.debug.print("Invalid nullclaw-chat-ui archive layout for {s}\n", .{tag});
        std.debug.print("Download manually from: {s}\n", .{html_url});
        return error.InvalidArchiveLayout;
    }

    try writeCurrentVersion(allocator, base_dir, tag);
    std.debug.print("Installed nullclaw-chat-ui {s}\n", .{tag});
    std.debug.print("Active UI path: {s}\n", .{package_dir});
}

fn getLatestRelease(allocator: std.mem.Allocator) !ReleaseInfo {
    const url = "https://api.github.com/repos/" ++ repo_owner ++ "/" ++ repo_name ++ "/releases/latest";

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-sSfL", "--max-time", "30", url },
        .max_output_bytes = 10 * 1024 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.CurlNotFound,
        else => return err,
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    switch (result.term) {
        .Exited => |code| if (code != 0) {
            const stderr_trimmed = std.mem.trim(u8, result.stderr, " \t\r\n");
            const releases_url = "https://github.com/" ++ repo_owner ++ "/" ++ repo_name ++ "/releases";
            if (std.mem.indexOf(u8, stderr_trimmed, "404") != null) {
                std.debug.print("No published {s} release found yet.\n", .{repo_name});
                std.debug.print("Publish a release first: {s}\n", .{releases_url});
                return error.NoReleaseFound;
            }
            if (stderr_trimmed.len > 0) {
                std.debug.print("Failed to query latest {s} release: {s}\n", .{ repo_name, stderr_trimmed });
            } else {
                std.debug.print("Failed to query latest {s} release.\n", .{repo_name});
            }
            std.debug.print("Check releases page: {s}\n", .{releases_url});
            return error.ReleaseLookupFailed;
        },
        else => return error.ReleaseLookupFailed,
    }

    if (result.stdout.len == 0) return error.EmptyResponse;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch |err| {
        log.err("latest release JSON parse failed: {}", .{err});
        return error.InvalidJson;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidJson;

    const tag_name_val = root.object.get("tag_name") orelse return error.MissingField;
    const html_url_val = root.object.get("html_url") orelse return error.MissingField;
    const published_at_val = root.object.get("published_at") orelse return error.MissingField;
    const body_val = root.object.get("body") orelse return error.MissingField;

    if (tag_name_val != .string or html_url_val != .string or published_at_val != .string or body_val != .string) {
        return error.InvalidFieldType;
    }

    return .{
        .tag_name = try allocator.dupe(u8, tag_name_val.string),
        .html_url = try allocator.dupe(u8, html_url_val.string),
        .published_at = try allocator.dupe(u8, published_at_val.string),
        .body = try allocator.dupe(u8, body_val.string),
    };
}

fn uiBaseDir(allocator: std.mem.Allocator) ![]u8 {
    const home = try platform.getHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".nullclaw", "ui" });
}

fn versionsDir(allocator: std.mem.Allocator, base_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ base_dir, "versions" });
}

fn currentVersionPath(allocator: std.mem.Allocator, base_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ base_dir, current_version_filename });
}

fn versionDirForTag(allocator: std.mem.Allocator, base_dir: []const u8, tag: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ base_dir, "versions", tag });
}

fn packageDirForTag(allocator: std.mem.Allocator, base_dir: []const u8, tag: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ base_dir, "versions", tag, package_dir_name });
}

fn resolveActivePackageDir(allocator: std.mem.Allocator) !?[]u8 {
    const base_dir = try uiBaseDir(allocator);
    defer allocator.free(base_dir);

    const current_tag_opt = try readCurrentVersion(allocator, base_dir);
    defer if (current_tag_opt) |tag| allocator.free(tag);

    if (current_tag_opt) |tag| {
        const package_dir = try packageDirForTag(allocator, base_dir, tag);
        if (pathExists(package_dir)) {
            return package_dir;
        }
        allocator.free(package_dir);
    }
    return null;
}

fn readCurrentVersion(allocator: std.mem.Allocator, base_dir: []const u8) !?[]u8 {
    const path = try currentVersionPath(allocator, base_dir);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const raw = try file.readToEndAlloc(allocator, 256);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(raw);
        return null;
    }
    if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) return raw;

    const tag = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return tag;
}

fn writeCurrentVersion(allocator: std.mem.Allocator, base_dir: []const u8, tag: []const u8) !void {
    const path = try currentVersionPath(allocator, base_dir);
    defer allocator.free(path);

    try ensureDirAbsolute(base_dir);
    var file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(tag);
    try file.writeAll("\n");
}

fn ensureDirAbsolute(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => try std.fs.cwd().makePath(path),
        else => return err,
    };
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn archiveSuffixForOs(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows) ".zip" else ".tar.gz";
}

fn archiveSuffix() []const u8 {
    return archiveSuffixForOs(builtin.os.tag);
}

fn assetNameForTag(allocator: std.mem.Allocator, tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}-{s}{s}", .{ package_dir_name, tag, archiveSuffix() });
}

fn downloadUrlForTag(allocator: std.mem.Allocator, tag: []const u8) ![]u8 {
    const asset_name = try assetNameForTag(allocator, tag);
    defer allocator.free(asset_name);
    return std.fmt.allocPrint(
        allocator,
        "https://github.com/{s}/{s}/releases/download/{s}/{s}",
        .{ repo_owner, repo_name, tag, asset_name },
    );
}

fn downloadToPath(allocator: std.mem.Allocator, url: []const u8, out_path: []const u8) !usize {
    var file = try std.fs.createFileAbsolute(out_path, .{ .read = true });
    defer file.close();
    return downloadToFile(allocator, url, &file);
}

fn downloadToFile(allocator: std.mem.Allocator, url: []const u8, file: *std.fs.File) !usize {
    const argv = &[_][]const u8{ "curl", "-sfL", "--max-time", "60", url };
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch |err| switch (err) {
        error.FileNotFound => return error.CurlNotFound,
        else => return err,
    };

    const stdout = child.stdout.?;
    var total: usize = 0;
    var buf: [64 * 1024]u8 = undefined;

    while (true) {
        const n = stdout.read(&buf) catch |err| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return err;
        };
        if (n == 0) break;
        try file.writeAll(buf[0..n]);
        total += n;
    }

    const term = child.wait() catch return error.CurlFailed;
    switch (term) {
        .Exited => |code| if (code != 0) return error.CurlFailed,
        else => return error.CurlFailed,
    }

    return total;
}

fn runCheckedInherit(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch |err| switch (err) {
        error.FileNotFound => return error.CommandNotFound,
        else => return err,
    };

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn escapePowerShellLiteral(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    for (input) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "''");
        } else {
            try out.append(allocator, ch);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn extractArchive(allocator: std.mem.Allocator, archive_path: []const u8, dest_dir: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const escaped_archive = try escapePowerShellLiteral(allocator, archive_path);
        defer allocator.free(escaped_archive);
        const escaped_dest = try escapePowerShellLiteral(allocator, dest_dir);
        defer allocator.free(escaped_dest);
        const cmd = try std.fmt.allocPrint(
            allocator,
            "Expand-Archive -LiteralPath '{s}' -DestinationPath '{s}' -Force",
            .{ escaped_archive, escaped_dest },
        );
        defer allocator.free(cmd);
        try runCheckedInherit(allocator, &.{ "powershell", "-NoProfile", "-Command", cmd });
        return;
    }

    try runCheckedInherit(allocator, &.{ "tar", "-xzf", archive_path, "-C", dest_dir });
}

fn ensureNodeRuntime(allocator: std.mem.Allocator) !void {
    const major = getNodeMajorVersion(allocator) catch |err| switch (err) {
        error.NodeNotFound => {
            std.debug.print("`node` was not found in PATH.\n", .{});
            std.debug.print("Install Node.js {d}+ and retry.\n", .{node_min_major});
            return err;
        },
        error.InvalidNodeVersion => {
            std.debug.print("Unable to parse `node --version` output.\n", .{});
            return err;
        },
        else => return err,
    };

    if (major < node_min_major) {
        std.debug.print("Detected Node.js v{d}, but nullclaw-chat-ui requires Node.js {d}+.\n", .{
            major,
            node_min_major,
        });
        return error.NodeVersionTooOld;
    }
}

fn getNodeMajorVersion(allocator: std.mem.Allocator) !u32 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "node", "--version" },
        .max_output_bytes = 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.NodeNotFound,
        else => return err,
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    switch (result.term) {
        .Exited => |code| if (code != 0) return error.InvalidNodeVersion,
        else => return error.InvalidNodeVersion,
    }
    return parseNodeMajorVersion(result.stdout);
}

pub fn parseNodeMajorVersion(raw: []const u8) !u32 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidNodeVersion;

    var version = trimmed;
    if (version[0] == 'v') {
        version = version[1..];
    }
    if (version.len == 0) return error.InvalidNodeVersion;

    var end: usize = 0;
    while (end < version.len and std.ascii.isDigit(version[end])) : (end += 1) {}
    if (end == 0) return error.InvalidNodeVersion;

    return std.fmt.parseInt(u32, version[0..end], 10) catch error.InvalidNodeVersion;
}

fn runUiProcess(allocator: std.mem.Allocator, script_path: []const u8, run_args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{ "node", script_path, "run" });
    for (run_args) |arg| try argv.append(allocator, arg);

    try runCheckedInherit(allocator, argv.items);
}

fn readLine(allocator: std.mem.Allocator) ![]const u8 {
    const stdin = std.fs.File.stdin();
    var buffer: [256]u8 = undefined;
    var pos: usize = 0;
    while (pos < buffer.len) {
        const n = try stdin.read(buffer[pos .. pos + 1]);
        if (n == 0) return error.EndOfStream;
        if (buffer[pos] == '\n') break;
        pos += 1;
    }
    const trimmed = std.mem.trimRight(u8, buffer[0..pos], "\r");
    return allocator.dupe(u8, trimmed);
}

fn stripV(v: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, v, "v")) v[1..] else v;
}

test "archive suffix uses zip on windows and tar.gz otherwise" {
    try std.testing.expectEqualStrings(".zip", archiveSuffixForOs(.windows));
    try std.testing.expectEqualStrings(".tar.gz", archiveSuffixForOs(.linux));
    try std.testing.expectEqualStrings(".tar.gz", archiveSuffixForOs(.macos));
}

test "parseNodeMajorVersion supports standard node outputs" {
    try std.testing.expectEqual(@as(u32, 20), try parseNodeMajorVersion("v20.12.2\n"));
    try std.testing.expectEqual(@as(u32, 22), try parseNodeMajorVersion("22.3.0"));
    try std.testing.expectError(error.InvalidNodeVersion, parseNodeMajorVersion("node"));
}

test "asset and download names are deterministic" {
    const allocator = std.testing.allocator;
    const tag = "v2026.3.4";
    const asset = try assetNameForTag(allocator, tag);
    defer allocator.free(asset);
    try std.testing.expect(std.mem.startsWith(u8, asset, "nullclaw-chat-ui-v2026.3.4"));

    const url = try downloadUrlForTag(allocator, tag);
    defer allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "/releases/download/v2026.3.4/") != null);
}
