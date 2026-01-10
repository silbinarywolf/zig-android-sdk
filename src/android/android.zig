const std = @import("std");
const builtin = @import("builtin");

const ndk = @import("ndk");
const zig014 = @import("zig014");
const zig015 = @import("zig015");
const zig016 = @import("zig016");

const Logger = @import("Logger.zig");
const Level = ndk.Level;

/// Alternate panic implementation that calls __android_log_write so that you can see the logging via "adb logcat"
pub const panic = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
    std.debug.FullPanic(@import("Zig015_Panic.zig").panic)
else
    @compileError("Android panic handler is no longer maintained as of Zig 0.16.x-dev");

/// Alternate log function implementation that calls __android_log_write so that you can see the logging via "adb logcat"
pub const logFn = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 14)
    zig014.LogWriter.logFn
else if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
    zig015.wrapLogFn(androidLogFn)
else
    zig016.wrapLogFn(androidLogFn);

fn androidLogFn(
    comptime message_level: std.log.Level,
    // NOTE(jae): 2026-01-10
    // Just make our log function here use the precomputed text and get the Zig 0.15.2 and Zig 0.16.x-dev+
    // implementation to pass in the following:
    // - const scope_prefix_text = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")"; // "): ";
    comptime scope_prefix_text: [:0]const u8,
    comptime format: []const u8,
    args: anytype,
) void {
    // If there are no arguments or '{}' patterns in the logging, just call Android log directly
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);
    if (args_type_info != .@"struct") {
        @compileError("expected tuple or struct argument, found " ++ @typeName(ArgsType));
    }

    const android_log_level: Level = switch (message_level) {
        //  => .ANDROID_LOG_VERBOSE, // No mapping
        .debug => .debug, // android.ANDROID_LOG_DEBUG = 3,
        .info => .info, // android.ANDROID_LOG_INFO = 4,
        .warn => .warn, // android.ANDROID_LOG_WARN = 5,
        .err => .err, // android.ANDROID_LOG_WARN = 6,
    };

    const fields_info = args_type_info.@"struct".fields;
    if (fields_info.len == 0 and
        comptime std.mem.indexOfScalar(u8, format, '{') == null)
    {
        // If no formatting, log string directly with Android logging
        _ = Logger.logString(android_log_level, format);
        return;
    }
    var buffer: [8192]u8 = undefined;
    var logger = Logger.init(android_log_level, &buffer);
    nosuspend {
        logger.writer.print(scope_prefix_text ++ format ++ "\n", args) catch return;
        logger.writer.flush() catch return;
    }
}
