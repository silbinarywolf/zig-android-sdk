//! Panic is a copy-paste of the panic logic from Zig but replaces usages of getStdErr with our own writer
//! This is deprecated from Zig 0.16.x-dev onwards due to being buggy and hard to maintain.
//!
//! Example output (Zig 0.13.0):
//! 09-22 13:08:49.578  3390  3390 F com.zig.minimal: thread 3390 panic: your panic message here
//! 09-22 13:08:49.637  3390  3390 F com.zig.minimal: zig-android-sdk/examples\minimal/src/minimal.zig:33:15: 0x7ccb77b282dc in nativeActivityOnCreate (minimal)
//! 09-22 13:08:49.637  3390  3390 F com.zig.minimal: zig-android-sdk/examples/minimal/src/minimal.zig:84:27: 0x7ccb77b28650 in ANativeActivity_onCreate (minimal)
//! 09-22 13:08:49.637  3390  3390 F com.zig.minimal: ???:?:?: 0x7ccea4021d9c in ??? (libandroid_runtime.so)

const std = @import("std");
const ndk = @import("ndk");
const builtin = @import("builtin");
const Logger = @import("Logger.zig");

const Level = ndk.Level;

const package_name = @import("android_builtin").package_name;

const LogWriter_Zig014 = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 14)
    @import("zig014").LogWriter
else
    void;

/// Non-zero whenever the program triggered a panic.
/// The counter is incremented/decremented atomically.
var panicking = std.atomic.Value(u8).init(0);

/// Counts how many times the panic handler is invoked by this thread.
/// This is used to catch and handle panics triggered by the panic handler.
threadlocal var panic_stage: usize = 0;

pub fn panic(message: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    if (comptime !builtin.abi.isAndroid()) @compileError("do not use Android panic for non-Android builds");

    const first_trace_addr = ret_addr orelse @returnAddress();
    panicImpl(first_trace_addr, message);
}

/// Must be called only after adding 1 to `panicking`. There are three callsites.
fn waitForOtherThreadToFinishPanicking() void {
    if (panicking.fetchSub(1, .seq_cst) != 1) {
        // Another thread is panicking, wait for the last one to finish
        // and call abort()
        if (builtin.single_threaded) unreachable;

        // Sleep forever without hammering the CPU
        var futex = std.atomic.Value(u32).init(0);
        while (true) std.Thread.Futex.wait(&futex, 0);
        unreachable;
    }
}

fn resetSegfaultHandler() void {
    // NOTE(jae): 2024-09-22
    // Not applicable for Android as it runs on the OS tag Linux
    // if (builtin.os.tag == .windows) {
    //     if (windows_segfault_handle) |handle| {
    //         assert(windows.kernel32.RemoveVectoredExceptionHandler(handle) != 0);
    //         windows_segfault_handle = null;
    //     }
    //     return;
    // }
    var act = posix.Sigaction{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = if (builtin.zig_version.major == 0 and builtin.zig_version.minor == 14)
            // Legacy 0.14.0
            posix.empty_sigset
        else
            // 0.15.0-dev+
            posix.sigemptyset(),
        .flags = 0,
    };
    std.debug.updateSegfaultHandler(&act);
}

const io = struct {
    /// Collect data in writer buffer and flush to Android logs per newline
    var android_log_writer_buffer: [8192]u8 = undefined;

    /// The primary motivation for recursive mutex here is so that a panic while
    /// android log writer mutex is held still dumps the stack trace and other debug
    /// information.
    var android_log_writer_mutex = std.Thread.Mutex.Recursive.init;

    var android_panic_log_writer = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 14)
        LogWriter_Zig014{ .level = .fatal }
    else
        Logger.init(.fatal, &android_log_writer_buffer);

    fn lockAndroidLogWriter() if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 14)
        LogWriter_Zig014.GenericWriter
    else
        *std.Io.Writer {
        android_log_writer_mutex.lock();
        if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 14) {
            android_panic_log_writer.flush();
            return android_panic_log_writer.writer();
        } else {
            android_panic_log_writer.writer.flush() catch {};
            return &android_panic_log_writer.writer;
        }
    }

    fn unlockAndroidLogWriter() void {
        if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 14) {
            android_panic_log_writer.flush();
        } else {
            android_panic_log_writer.writer.flush() catch {};
        }
        android_log_writer_mutex.unlock();
    }
};

const posix = std.posix;

/// Panic is a copy-paste of the panic logic from Zig but replaces usages of getStdErr with our own writer
///
/// - Provide custom "io" namespace so we can easily customize getStdErr() to be our own writer
/// - Provide other functions from std.debug.*
fn panicImpl(first_trace_addr: ?usize, msg: []const u8) noreturn {
    @branchHint(.cold);

    if (std.options.enable_segfault_handler) {
        // If a segfault happens while panicking, we want it to actually segfault, not trigger
        // the handler.
        resetSegfaultHandler();
    }

    // Note there is similar logic in handleSegfaultPosix and handleSegfaultWindowsExtra.
    nosuspend switch (panic_stage) {
        0 => {
            panic_stage = 1;

            _ = panicking.fetchAdd(1, .seq_cst);

            // Make sure to release the mutex when done
            {
                if (builtin.single_threaded) {
                    _ = ndk.__android_log_print(
                        @intFromEnum(Level.fatal),
                        comptime if (package_name.len == 0) null else package_name.ptr,
                        "panic: %.*s",
                        msg.len,
                        msg.ptr,
                    );
                } else {
                    const current_thread_id: u32 = std.Thread.getCurrentId();
                    _ = ndk.__android_log_print(
                        @intFromEnum(Level.fatal),
                        comptime if (package_name.len == 0) null else package_name.ptr,
                        "thread %d panic: %.*s",
                        current_thread_id,
                        msg.len,
                        msg.ptr,
                    );
                }
                if (@errorReturnTrace()) |t| dumpStackTrace(t.*);
                if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 14) {
                    dumpCurrentStackTrace_014(first_trace_addr);
                } else {
                    const stderr = io.lockAndroidLogWriter();
                    defer io.unlockAndroidLogWriter();
                    std.debug.dumpCurrentStackTraceToWriter(first_trace_addr orelse @returnAddress(), stderr) catch {};
                }
            }

            waitForOtherThreadToFinishPanicking();
        },
        1 => {
            panic_stage = 2;

            // A panic happened while trying to print a previous panic message,
            // we're still holding the mutex but that's fine as we're going to
            // call abort()
            android_fatal_log("Panicked during a panic. Aborting.");
        },
        else => {
            // Panicked while printing "Panicked during a panic."
        },
    };

    @trap();
}

fn dumpStackTrace(stack_trace: std.builtin.StackTrace) void {
    nosuspend {
        if (comptime builtin.target.cpu.arch.isWasm()) {
            @compileError("cannot use Android logger with Wasm");
        }
        if (builtin.strip_debug_info) {
            android_fatal_log("Unable to dump stack trace: debug info stripped");
        }
        const debug_info = std.debug.getSelfDebugInfo() catch |err| {
            android_fatal_print_c_string("Unable to dump stack trace: Unable to open debug info: %s", @errorName(err));
            return;
        };
        const stderr = io.lockAndroidLogWriter();
        defer io.unlockAndroidLogWriter();
        std.debug.writeStackTrace(stack_trace, stderr, debug_info, .no_color) catch |err| {
            android_fatal_print_c_string("Unable to dump stack trace: %s", @errorName(err));
            return;
        };
    }
}

/// Deprecated: Only used for current Zig 0.14.1 stable builds,
fn dumpCurrentStackTrace_014(start_addr: ?usize) void {
    nosuspend {
        if (comptime builtin.target.cpu.arch.isWasm()) {
            @compileError("cannot use Android logger with Wasm");
        }
        if (builtin.strip_debug_info) {
            android_fatal_log("Unable to dump stack trace: debug info stripped");
            return;
        }
        const debug_info = std.debug.getSelfDebugInfo() catch |err| {
            android_fatal_print_c_string("Unable to dump stack trace: Unable to open debug info: %s", @errorName(err));
            return;
        };
        const stderr = io.lockAndroidLogWriter();
        defer io.unlockAndroidLogWriter();
        std.debug.writeCurrentStackTrace(stderr, debug_info, .no_color, start_addr) catch |err| {
            android_fatal_print_c_string("Unable to dump stack trace: %s", @errorName(err));
            return;
        };
    }
}

fn android_fatal_log(message: [:0]const u8) void {
    _ = ndk.__android_log_write(
        @intFromEnum(Level.fatal),
        comptime if (package_name.len == 0) null else package_name.ptr,
        message,
    );
}

fn android_fatal_print_c_string(
    comptime fmt: [:0]const u8,
    c_str: [:0]const u8,
) void {
    _ = ndk.__android_log_print(
        @intFromEnum(Level.fatal),
        comptime if (package_name.len == 0) null else package_name.ptr,
        fmt,
        c_str.ptr,
    );
}

const Panic = @This();
