const builtin = @import("builtin");

const android = @import("android");

comptime {
    // For external translate-c usage, validate at compile-time that this symbol exists
    _ = @import("translate_c_external").__android_log_write;
}
