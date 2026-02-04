//! Seperate module for Zig 0.16.X-dev functionality as @Type() comptime directive was removed

const std = @import("std");
const builtin = @import("builtin");
const ndk = @import("ndk");

const android_builtin = @import("android_builtin");
const package_name: ?[*:0]const u8 = if (android_builtin.package_name.len > 0) android_builtin.package_name else null;

const LogFunction = fn (comptime message_level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void;

pub fn wrapLogFn(comptime logFn: fn (
    comptime message_level: std.log.Level,
    comptime scope_prefix_text: [:0]const u8,
    comptime format: []const u8,
    args: anytype,
) void) LogFunction {
    return struct {
        fn standardLogFn(comptime message_level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
            // NOTE(jae): 2024-09-11
            // Zig has a colon ": " or "): " for scoped but Android logs just do that after being flushed
            // So we don't do that here.
            const scope_prefix_text = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")"; // "): ";
            return logFn(message_level, scope_prefix_text, format, args);
        }
    }.standardLogFn;
}

pub fn panic(message: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    if (comptime !builtin.abi.isAndroid()) @compileError("do not use Android panic for non-Android builds");

    const android_log_level: c_int = @intFromEnum(ndk.Level.fatal);

    trace: {
        _ = ndk.__android_log_print(android_log_level, package_name, "panic: %.*s", message.len, message.ptr);

        if (@errorReturnTrace()) |t| if (t.index > 0) {
            logFatal("error return context:");
            writeStackTrace(t) catch break :trace;
            logFatal("\nstack trace:\n");
        };
        if (!std.options.allow_stack_tracing) {
            logFatal("Cannot print stack trace: stack tracing is disabled");
            return;
        } else {
            _ = ndk.__android_log_print(android_log_level, package_name, "  at address: 0x%X", first_trace_addr orelse @returnAddress());
            logFatal("  (stack trace printing not supported in Zig 0.16.X+ for Android SDK)");
        }
    }

    @trap();
}

/// Write a previously captured stack trace to `writer`, annotated with source locations.
pub fn writeStackTrace(st: *const std.builtin.StackTrace) !void {
    if (!std.options.allow_stack_tracing) {
        logFatal("Cannot print stack trace: stack tracing is disabled");
        return;
    }

    // Fetch `st.index` straight away. Aside from avoiding redundant loads, this prevents issues if
    // `st` is `@errorReturnTrace()` and errors are encountered while writing the stack trace.
    const n_frames = st.index;
    if (n_frames == 0) return logFatal("(empty stack trace)");

    const captured_frames = @min(n_frames, st.instruction_addresses.len);
    logFatal("(stack trace support unimplemented for Zig 0.16.X+)");

    // const di_gpa = std.debug.getDebugInfoAllocator();
    // const di = std.debug.getSelfDebugInfo() catch |err| switch (err) {
    //     error.UnsupportedTarget => {
    //         logFatal("Cannot print stack trace: debug info unavailable for target\n\n");
    //         return;
    //     },
    // };
    // const io = std.Options.debug_io;
    //
    // for (st.instruction_addresses[0..captured_frames]) |ret_addr| {
    //     // `ret_addr` is the return address, which is *after* the function call.
    //     // Subtract 1 to get an address *in* the function call for a better source location.
    //     try printSourceAtAddress(di_gpa, io, di, t, ret_addr -| StackIterator.ra_call_offset);
    // }
    if (n_frames > captured_frames) {
        _ = ndk.__android_log_print(
            @intFromEnum(ndk.Level.fatal),
            package_name,
            "(%d additional stack frames skipped...)",
            n_frames - captured_frames,
        );
    }
}

inline fn logFatal(text: []const u8) void {
    _ = ndk.__android_log_print(
        @intFromEnum(ndk.Level.fatal),
        package_name,
        "%.*s",
        text.len,
        text.ptr,
    );
}
