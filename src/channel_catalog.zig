const std = @import("std");
const Config = @import("config.zig").Config;

pub const ChannelId = enum {
    cli,
    telegram,
    discord,
    slack,
    webhook,
    imessage,
    matrix,
    whatsapp,
    irc,
    lark,
    dingtalk,
    signal,
    email,
    line,
    qq,
    onebot,
    maixcam,
};

pub const ChannelMeta = struct {
    id: ChannelId,
    key: []const u8,
    label: []const u8,
    configured_message: []const u8,
};

pub const known_channels = [_]ChannelMeta{
    .{ .id = .cli, .key = "cli", .label = "CLI", .configured_message = "CLI enabled" },
    .{ .id = .telegram, .key = "telegram", .label = "Telegram", .configured_message = "Telegram configured" },
    .{ .id = .discord, .key = "discord", .label = "Discord", .configured_message = "Discord configured" },
    .{ .id = .slack, .key = "slack", .label = "Slack", .configured_message = "Slack configured" },
    .{ .id = .webhook, .key = "webhook", .label = "Webhook", .configured_message = "Webhook configured" },
    .{ .id = .imessage, .key = "imessage", .label = "iMessage", .configured_message = "iMessage configured" },
    .{ .id = .matrix, .key = "matrix", .label = "Matrix", .configured_message = "Matrix configured" },
    .{ .id = .whatsapp, .key = "whatsapp", .label = "WhatsApp", .configured_message = "WhatsApp configured" },
    .{ .id = .irc, .key = "irc", .label = "IRC", .configured_message = "IRC configured" },
    .{ .id = .lark, .key = "lark", .label = "Lark", .configured_message = "Lark configured" },
    .{ .id = .dingtalk, .key = "dingtalk", .label = "DingTalk", .configured_message = "DingTalk configured" },
    .{ .id = .signal, .key = "signal", .label = "Signal", .configured_message = "Signal configured" },
    .{ .id = .email, .key = "email", .label = "Email", .configured_message = "Email configured" },
    .{ .id = .line, .key = "line", .label = "Line", .configured_message = "Line configured" },
    .{ .id = .qq, .key = "qq", .label = "QQ", .configured_message = "QQ configured" },
    .{ .id = .onebot, .key = "onebot", .label = "OneBot", .configured_message = "OneBot configured" },
    .{ .id = .maixcam, .key = "maixcam", .label = "MaixCam", .configured_message = "MaixCam configured" },
};

pub fn configuredCount(cfg: *const Config, channel_id: ChannelId) usize {
    return switch (channel_id) {
        .cli => if (cfg.channels.cli) 1 else 0,
        .telegram => cfg.channels.telegram.len,
        .discord => cfg.channels.discord.len,
        .slack => cfg.channels.slack.len,
        .webhook => if (cfg.channels.webhook != null) 1 else 0,
        .imessage => if (cfg.channels.imessage != null) 1 else 0,
        .matrix => if (cfg.channels.matrix != null) 1 else 0,
        .whatsapp => if (cfg.channels.whatsapp != null) 1 else 0,
        .irc => if (cfg.channels.irc != null) 1 else 0,
        .lark => if (cfg.channels.lark != null) 1 else 0,
        .dingtalk => if (cfg.channels.dingtalk != null) 1 else 0,
        .signal => cfg.channels.signal.len,
        .email => if (cfg.channels.email != null) 1 else 0,
        .line => if (cfg.channels.line != null) 1 else 0,
        .qq => cfg.channels.qq.len,
        .onebot => cfg.channels.onebot.len,
        .maixcam => cfg.channels.maixcam.len,
    };
}

pub fn isConfigured(cfg: *const Config, channel_id: ChannelId) bool {
    return configuredCount(cfg, channel_id) > 0;
}

pub fn statusText(cfg: *const Config, meta: ChannelMeta, buf: []u8) []const u8 {
    const count = configuredCount(cfg, meta.id);
    if (meta.id == .cli) {
        return if (count > 0) "enabled" else "disabled";
    }
    if (count == 0) return "not configured";
    if (count == 1) return "configured";
    return std.fmt.bufPrint(buf, "configured ({d} accounts)", .{count}) catch "configured";
}

pub fn findByKey(key: []const u8) ?ChannelMeta {
    for (known_channels) |meta| {
        if (std.mem.eql(u8, meta.key, key)) return meta;
    }
    return null;
}

pub fn hasAnyConfigured(cfg: *const Config, include_cli: bool) bool {
    for (known_channels) |meta| {
        if (!include_cli and meta.id == .cli) continue;
        if (isConfigured(cfg, meta.id)) return true;
    }
    return false;
}

pub fn contributesToDaemonSupervision(channel_id: ChannelId) bool {
    return switch (channel_id) {
        .cli, .webhook => false,
        else => true,
    };
}

pub fn hasSupervisedChannels(cfg: *const Config) bool {
    for (known_channels) |meta| {
        if (!contributesToDaemonSupervision(meta.id)) continue;
        if (isConfigured(cfg, meta.id)) return true;
    }
    return false;
}

pub fn isChannelStartSupported(channel_id: ChannelId) bool {
    return switch (channel_id) {
        .telegram, .signal, .discord, .qq, .onebot => true,
        else => false,
    };
}

test "configuredCount handles array and optional channels" {
    const cfg = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .telegram = &[_]@import("config_types.zig").TelegramConfig{
                .{ .account_id = "main", .bot_token = "tok" },
            },
            .qq = &[_]@import("config_types.zig").QQConfig{
                .{ .account_id = "main" },
                .{ .account_id = "backup" },
            },
            .whatsapp = .{
                .account_id = "main",
                .access_token = "a",
                .phone_number_id = "b",
                .verify_token = "c",
            },
        },
    };

    try std.testing.expectEqual(@as(usize, 1), configuredCount(&cfg, .telegram));
    try std.testing.expectEqual(@as(usize, 2), configuredCount(&cfg, .qq));
    try std.testing.expectEqual(@as(usize, 1), configuredCount(&cfg, .whatsapp));
    try std.testing.expectEqual(@as(usize, 0), configuredCount(&cfg, .line));
}

test "hasSupervisedChannels excludes webhook and cli" {
    const cfg_webhook_only = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .cli = true,
            .webhook = .{ .port = 8080 },
        },
    };
    try std.testing.expect(!hasSupervisedChannels(&cfg_webhook_only));

    const cfg_signal = Config{
        .workspace_dir = "/tmp",
        .config_path = "/tmp/config.json",
        .allocator = std.testing.allocator,
        .channels = .{
            .signal = &[_]@import("config_types.zig").SignalConfig{
                .{
                    .account_id = "main",
                    .http_url = "http://localhost:8080",
                    .account = "+15550001111",
                },
            },
        },
    };
    try std.testing.expect(hasSupervisedChannels(&cfg_signal));
}

test "findByKey finds known channels" {
    const telegram = findByKey("telegram");
    try std.testing.expect(telegram != null);
    try std.testing.expectEqual(ChannelId.telegram, telegram.?.id);
    try std.testing.expectEqualStrings("Telegram", telegram.?.label);
    try std.testing.expect(findByKey("unknown") == null);
}
