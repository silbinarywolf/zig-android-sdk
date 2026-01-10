//! LogWriter_Zig014 was was taken basically as is from: https://github.com/ikskuh/ZigAndroidTemplate
//!
//! Deprecated: To be removed when Zig 0.15.x is stable

const std = @import("std");
const builtin = @import("builtin");
const ndk = @import("ndk");
const Level = ndk.Level;

level: Level,

line_buffer: [8192]u8 = undefined,
line_len: usize = 0,

const Error = error{};
pub const GenericWriter = std.io.GenericWriter(*LogWriter_Zig014, LogWriter_Zig014.Error, LogWriter_Zig014.write);
const Writer = std.io.Writer(*LogWriter_Zig014, Error, write);

const log_tag: [:0]const u8 = @import("android_builtin").package_name;

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // NOTE(jae): 2024-09-11
    // Zig has a colon ": " or "): " for scoped but Android logs just do that after being flushed
    // So we don't do that here.
    const prefix2 = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")"; // "): ";
    var androidLogWriter = comptime LogWriter_Zig014{
        .level = switch (message_level) {
            //  => .ANDROID_LOG_VERBOSE, // No mapping
            .debug => .debug, // android.ANDROID_LOG_DEBUG = 3,
            .info => .info, // android.ANDROID_LOG_INFO = 4,
            .warn => .warn, // android.ANDROID_LOG_WARN = 5,
            .err => .err, // android.ANDROID_LOG_WARN = 6,
        },
    };
    const logger = androidLogWriter.writer();

    nosuspend {
        logger.print(prefix2 ++ format ++ "\n", args) catch return;
        androidLogWriter.flush();
    }
}

fn write(self: *@This(), buffer: []const u8) Error!usize {
    for (buffer) |char| {
        switch (char) {
            '\n' => {
                self.flush();
            },
            else => {
                if (self.line_len >= self.line_buffer.len - 1) {
                    self.flush();
                }
                self.line_buffer[self.line_len] = char;
                self.line_len += 1;
            },
        }
    }
    return buffer.len;
}

pub fn flush(self: *@This()) void {
    if (self.line_len > 0) {
        std.debug.assert(self.line_len < self.line_buffer.len - 1);
        self.line_buffer[self.line_len] = 0;
        if (log_tag.len == 0) {
            _ = ndk.__android_log_write(
                @intFromEnum(self.level),
                null,
                &self.line_buffer,
            );
        } else {
            _ = ndk.__android_log_write(
                @intFromEnum(self.level),
                log_tag.ptr,
                &self.line_buffer,
            );
        }
    }
    self.line_len = 0;
}

pub fn writer(self: *@This()) Writer {
    return Writer{ .context = self };
}

const LogWriter_Zig014 = @This();
