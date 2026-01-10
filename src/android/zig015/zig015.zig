//! Seperate module for Zig 0.15.X functionality as @Type() comptime directive was removed

const std = @import("std");
const ndk = @import("../ndk.zig");
const Logger = @import("../Logger.zig");
const Level = Logger.Level;

/// Panic is the older Zig 0.14.x and 0.15.x panic handler
pub const Panic = @import("Panic_Zig014_015.zig");

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal), // From Zig 0.16.x, it's now: @EnumLiteral()
    comptime format: []const u8,
    args: anytype,
) void {
    // If there are no arguments or '{}' patterns in the logging, just call Android log directly
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);
    if (args_type_info != .@"struct") {
        @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
    }
    const fields_info = args_type_info.@"struct".fields;
    if (fields_info.len == 0 and
        comptime std.mem.indexOfScalar(u8, format, '{') == null)
    {
        _ = ndk.__android_log_print(
            @intFromEnum(Level.fatal),
            comptime if (Logger.tag.len == 0) null else Logger.tag.ptr,
            "%.*s",
            format.len,
            format.ptr,
        );
        return;
    }

    const android_log_level: Level = switch (message_level) {
        //  => .ANDROID_LOG_VERBOSE, // No mapping
        .debug => .debug, // android.ANDROID_LOG_DEBUG = 3,
        .info => .info, // android.ANDROID_LOG_INFO = 4,
        .warn => .warn, // android.ANDROID_LOG_WARN = 5,
        .err => .err, // android.ANDROID_LOG_WARN = 6,
    };
    var buffer: [8192]u8 = undefined;
    var logger = Logger.init(android_log_level, &buffer);

    // NOTE(jae): 2024-09-11
    // Zig has a colon ": " or "): " for scoped but Android logs just do that after being flushed
    // So we don't do that here.
    const prefix2 = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")"; // "): ";
    nosuspend {
        logger.writer.print(prefix2 ++ format ++ "\n", args) catch return;
        logger.writer.flush() catch return;
    }
}
