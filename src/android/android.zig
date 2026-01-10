const std = @import("std");
const builtin = @import("builtin");
const ndk = @import("ndk.zig");
const Logger = @import("Logger.zig");
const zig014 = @import("zig014");
const zig015 = @import("zig015");

// TODO(jae): 2024-10-03
// Consider exposing this in the future
// pub const builtin = android_builtin;

const android_builtin = struct {
    const ab = @import("android_builtin");

    /// package name extracted from your AndroidManifest.xml file
    /// ie. "com.zig.sdl2"
    pub const package_name: [:0]const u8 = ab.package_name;
};

const log_tag = Logger.tag;

/// Alternate panic implementation that calls __android_log_write so that you can see the logging via "adb logcat"
pub const panic = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
    std.debug.FullPanic(zig015.Panic.panic)
else
    void;

/// Log Levels for Android
pub const Level = Logger.Level;

/// Alternate log function implementation that calls __android_log_write so that you can see the logging via "adb logcat"
pub const logFn = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 14)
    zig014.LogWriter.logFn
else
    androidLogFn;

fn androidLogFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(), // @Type(.enum_literal),
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
            comptime if (log_tag.len == 0) null else log_tag.ptr,
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

fn android_fatal_log(message: [:0]const u8) void {
    _ = ndk.__android_log_write(
        @intFromEnum(Level.fatal),
        comptime if (log_tag.len == 0) null else log_tag.ptr,
        message,
    );
}

fn android_fatal_print_c_string(
    comptime fmt: [:0]const u8,
    c_str: [:0]const u8,
) void {
    _ = ndk.__android_log_print(
        @intFromEnum(Level.fatal),
        comptime if (log_tag.len == 0) null else log_tag.ptr,
        fmt,
        c_str.ptr,
    );
}
