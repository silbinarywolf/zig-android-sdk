//! NDK functions as defined at: https://developer.android.com/ndk/reference/group/logging

/// Writes the constant string text to the log, with priority prio and tag tag.
/// Returns: 1 if the message was written to the log, or -EPERM if it was not; see __android_log_is_loggable().
/// Source: https://developer.android.com/ndk/reference/group/logging
pub extern "log" fn __android_log_write(prio: c_int, tag: [*c]const u8, text: [*c]const u8) c_int;

/// Writes a formatted string to the log, with priority prio and tag tag.
/// The details of formatting are the same as for printf(3)
/// Returns: 1 if the message was written to the log, or -EPERM if it was not; see __android_log_is_loggable().
/// Source: https://man7.org/linux/man-pages/man3/printf.3.html
pub extern "log" fn __android_log_print(prio: c_int, tag: [*c]const u8, text: [*c]const u8, ...) c_int;

/// Log Levels for Android
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
