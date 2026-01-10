//! Logger is a Writer interface that logs out to Android via "__android_log_write" calls

const std = @import("std");
const ndk = @import("ndk.zig");
const Writer = std.Io.Writer;

/// Default to the "package" attribute defined in AndroidManifest.xml
///
/// If tag isn't set when calling "__android_log_write" then it *usually* defaults to the current
/// package name, ie. "com.zig.minimal"
///
/// However if running via a seperate thread, then it seems to use that threads
/// tag, which means if you log after running code through sdl_main, it won't print
/// logs with the package name.
///
/// To workaround this, we bake the package name into the Zig binaries.
pub const tag: [:0]const u8 = @import("android_builtin").package_name;

level: Level,
writer: Writer,

const vtable: Writer.VTable = .{
    .drain = Logger.drain,
};

pub fn init(level: Level, buffer: []u8) Logger {
    return .{
        .level = level,
        .writer = .{
            .buffer = buffer,
            .vtable = &vtable,
        },
    };
}

fn log_each_newline(logger: *Logger, buffer: []const u8) Writer.Error!usize {
    var written: usize = 0;
    var bytes_to_log = buffer;
    while (std.mem.indexOfScalar(u8, bytes_to_log, '\n')) |newline_pos| {
        const line = bytes_to_log[0..newline_pos];
        bytes_to_log = bytes_to_log[newline_pos + 1 ..];
        android_log_string(logger.level, line);
        written += line.len;
    }
    if (bytes_to_log.len == 0) return written;
    android_log_string(logger.level, bytes_to_log);
    written += bytes_to_log.len;
    return written;
}

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const logger: *Logger = @alignCast(@fieldParentPtr("writer", w));
    var written: usize = 0;

    // Consume 'buffer[0..end]' first
    written += try logger.log_each_newline(w.buffer[0..w.end]);
    w.end = 0;

    // NOTE(jae): 2025-07-27
    // The logic below should probably try to collect the buffers / pattern
    // below into one buffer first so that newlines are handled as expected but I'm not willing
    // to put the effort in.

    // Write additional overflow data
    const slice = data[0 .. data.len - 1];
    for (slice) |bytes| {
        written += try logger.log_each_newline(bytes);
    }

    // The last element of data is repeated as necessary
    const pattern = data[data.len - 1];
    switch (pattern.len) {
        0 => {},
        1 => {
            written += try logger.log_each_newline(pattern);
        },
        else => {
            for (0..splat) |_| {
                written += try logger.log_each_newline(pattern);
            }
        },
    }
    return written;
}

/// Levels for Android
pub const Level = enum(u8) {
    // silent = 8, // Android docs: For internal use only.
    // Fatal: Android only, for use when aborting
    fatal = 7, // ANDROID_LOG_FATAL
    /// Error: something has gone wrong. This might be recoverable or might
    /// be followed by the program exiting.
    err = 6, // ANDROID_LOG_ERROR
    /// Warning: it is uncertain if something has gone wrong or not, but the
    /// circumstances would be worth investigating.
    warn = 5, // ANDROID_LOG_WARN
    /// Info: general messages about the state of the program.
    info = 4, // ANDROID_LOG_INFO
    /// Debug: messages only useful for debugging.
    debug = 3, // ANDROID_LOG_DEBUG
    // verbose = 2, // ANDROID_LOG_VERBOSE
    // default = 1, // ANDROID_LOG_DEFAULT

    // Returns a string literal of the given level in full text form.
    // pub fn asText(comptime self: Level) []const u8 {
    //     return switch (self) {
    //         .err => "error",
    //         .warn => "warning",
    //         .info => "info",
    //         .debug => "debug",
    //     };
    // }
};

fn android_log_string(android_log_level: Level, text: []const u8) void {
    _ = ndk.__android_log_print(
        @intFromEnum(android_log_level),
        comptime if (tag.len == 0) null else tag.ptr,
        "%.*s",
        text.len,
        text.ptr,
    );
}

const Logger = @This();
