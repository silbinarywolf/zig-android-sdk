//! Test that a translate-c module will work recursively

comptime {
    // For external translate-c usage, validate at compile-time that this symbol exists
    _ = @import("translate_c_external_recursive").__android_log_write;
}
