/// Writes the constant string text to the log, with priority prio and tag tag.
/// Returns: 1 if the message was written to the log, or -EPERM if it was not; see __android_log_is_loggable().
/// Source: https://developer.android.com/ndk/reference/group/logging
pub extern "log" fn __android_log_write(prio: c_int, tag: [*c]const u8, text: [*c]const u8) c_int;

/// Writes a formatted string to the log, with priority prio and tag tag.
/// The details of formatting are the same as for printf(3)
/// Returns: 1 if the message was written to the log, or -EPERM if it was not; see __android_log_is_loggable().
/// Source: https://man7.org/linux/man-pages/man3/printf.3.html
pub extern "log" fn __android_log_print(prio: c_int, tag: [*c]const u8, text: [*c]const u8, ...) c_int;
