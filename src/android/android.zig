const std = @import("std");
const builtin = @import("builtin");

// TODO(jae): 2024-10-03
// Consider exposing this in the future
// pub const builtin = android_builtin;

const android_builtin = struct {
    const ab = @import("android_builtin");

    /// package name extracted from your AndroidManifest.xml file
    /// ie. "com.zig.sdl2"
    pub const package_name: [:0]const u8 = ab.package_name;
};

extern "log" fn __android_log_write(prio: c_int, tag: [*c]const u8, text: [*c]const u8) c_int;

/// Alternate panic implementation that calls __android_log_write so that you can see the logging via "adb logcat"
pub const panic = Panic.panic;

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

/// Alternate log function implementation that calls __android_log_write so that you can see the logging via "adb logcat"
pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: if (builtin.zig_version.major == 0 and builtin.zig_version.minor == 13)
        // Support Zig 0.13.0
        @Type(.EnumLiteral)
    else
        // Support Zig 0.14.0-dev
        @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // NOTE(jae): 2024-09-11
    // Zig has a colon ": " or "): " for scoped but Android logs just do that after being flushed
    // So we don't do that here.
    const prefix2 = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")"; // "): ";
    var androidLogWriter = comptime LogWriter{
        .level = switch (message_level) {
            //  => .ANDROID_LOG_VERBOSE, // No mapping
            .debug => .debug, // android.ANDROID_LOG_DEBUG = 3,
            .info => .info, // android.ANDROID_LOG_INFO = 4,
            .warn => .warn, // android.ANDROID_LOG_WARN = 5,
            .err => .err, // android.ANDROID_LOG_WARN = 6,
        },
    };
    const writer = androidLogWriter.writer();

    nosuspend {
        writer.print(prefix2 ++ format ++ "\n", args) catch return;
        androidLogWriter.flush();
    }
}

/// LogWriter was was taken basically as is from: https://github.com/ikskuh/ZigAndroidTemplate
const LogWriter = struct {
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
    var tag: [:0]const u8 = android_builtin.package_name;

    level: Level,

    line_buffer: [8192]u8 = undefined,
    line_len: usize = 0,

    const Error = error{};
    const Writer = std.io.Writer(*@This(), Error, write);

    fn write(self: *@This(), buffer: []const u8) Error!usize {
        for (buffer) |char| {
            switch (char) {
                '\n' => {
                    self.flush();
                },
                else => {
                    if (self.line_len >= self.line_buffer.len - 1) {
                        self.flush();
                    }
                    self.line_buffer[self.line_len] = char;
                    self.line_len += 1;
                },
            }
        }
        return buffer.len;
    }

    fn flush(self: *@This()) void {
        if (self.line_len > 0) {
            std.debug.assert(self.line_len < self.line_buffer.len - 1);
            self.line_buffer[self.line_len] = 0;
            if (tag.len == 0) {
                _ = __android_log_write(
                    @intFromEnum(self.level),
                    null,
                    &self.line_buffer,
                );
            } else {
                _ = __android_log_write(
                    @intFromEnum(self.level),
                    tag.ptr,
                    &self.line_buffer,
                );
            }
        }
        self.line_len = 0;
    }

    fn writer(self: *@This()) Writer {
        return Writer{ .context = self };
    }
};

/// Panic is a copy-paste of the panic logic from Zig but replaces usages of getStdErr with our own writer
///
/// Example output:
/// 09-22 13:08:49.578  3390  3390 F com.zig.minimal: thread 3390 panic: your panic message here
/// 09-22 13:08:49.637  3390  3390 F com.zig.minimal: zig-android-sdk/examples\minimal/src/minimal.zig:33:15: 0x7ccb77b282dc in nativeActivityOnCreate (minimal)
/// 09-22 13:08:49.637  3390  3390 F com.zig.minimal: zig-android-sdk/examples/minimal/src/minimal.zig:84:27: 0x7ccb77b28650 in ANativeActivity_onCreate (minimal)
/// 09-22 13:08:49.637  3390  3390 F com.zig.minimal: ???:?:?: 0x7ccea4021d9c in ??? (libandroid_runtime.so)
pub const Panic = struct {
    /// Non-zero whenever the program triggered a panic.
    /// The counter is incremented/decremented atomically.
    var panicking = std.atomic.Value(u8).init(0);

    // Locked to avoid interleaving panic messages from multiple threads.
    var panic_mutex = std.Thread.Mutex{};

    /// Counts how many times the panic handler is invoked by this thread.
    /// This is used to catch and handle panics triggered by the panic handler.
    threadlocal var panic_stage: usize = 0;

    pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
        const first_trace_addr = ret_addr orelse @returnAddress();
        panicImpl(stack_trace, first_trace_addr, message);
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

    const native_os = builtin.os.tag;
    const updateSegfaultHandler = std.debug.updateSegfaultHandler;

    fn resetSegfaultHandler() void {
        // NOTE(jae): 2024-09-22
        // Not applicable for Android as it runs on the OS tag Linux
        // if (native_os == .windows) {
        //     if (windows_segfault_handle) |handle| {
        //         assert(windows.kernel32.RemoveVectoredExceptionHandler(handle) != 0);
        //         windows_segfault_handle = null;
        //     }
        //     return;
        // }
        var act = posix.Sigaction{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.empty_sigset,
            .flags = 0,
        };
        // To avoid a double-panic, do nothing if an error happens here.
        if (builtin.zig_version.major == 0 and builtin.zig_version.minor == 13) {
            // Legacy 0.13.0
            updateSegfaultHandler(&act) catch {};
        } else {
            // 0.14.0-dev+
            updateSegfaultHandler(&act);
        }
    }

    const io = struct {
        const tty = struct {
            inline fn detectConfig(_: *LogWriter) std.io.tty.Config {
                return .no_color;
            }
        };

        var writer = LogWriter{
            .level = .fatal,
        };

        inline fn getStdErr() *LogWriter {
            return &writer;
        }
    };

    const posix = std.posix;
    const enable_segfault_handler = std.options.enable_segfault_handler;

    /// Panic is a copy-paste of the panic logic from Zig but replaces usages of getStdErr with our own writer
    ///
    /// - Provide custom "io" namespace so we can easily customize getStdErr() to be our own writer
    /// - Provide other functions from std.debug.*
    fn panicImpl(trace: ?*const std.builtin.StackTrace, first_trace_addr: ?usize, msg: []const u8) noreturn {
        // NOTE(jae): 2024-09-22
        // Cannot mark this as cold(true) OR setCold() depending on Zig version as we get an invalid builtin function
        // comptime {
        //     if (builtin.zig_version.minor == 13)
        //         @setCold(true)
        //     else
        //         @cold(true);
        // }

        if (enable_segfault_handler) {
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
                    panic_mutex.lock();
                    defer panic_mutex.unlock();

                    const stderr = io.getStdErr().writer();
                    if (builtin.single_threaded) {
                        stderr.print("panic: ", .{}) catch posix.abort();
                    } else {
                        const current_thread_id = std.Thread.getCurrentId();
                        stderr.print("thread {} panic: ", .{current_thread_id}) catch posix.abort();
                    }
                    stderr.print("{s}\n", .{msg}) catch posix.abort();
                    if (trace) |t| {
                        dumpStackTrace(t.*);
                    }
                    dumpCurrentStackTrace(first_trace_addr);
                }

                waitForOtherThreadToFinishPanicking();
            },
            1 => {
                panic_stage = 2;

                // A panic happened while trying to print a previous panic message,
                // we're still holding the mutex but that's fine as we're going to
                // call abort()
                const stderr = io.getStdErr().writer();
                stderr.print("Panicked during a panic. Aborting.\n", .{}) catch posix.abort();
            },
            else => {
                // Panicked while printing "Panicked during a panic."
            },
        };

        posix.abort();
    }

    const getSelfDebugInfo = std.debug.getSelfDebugInfo;
    const writeStackTrace = std.debug.writeStackTrace;

    // Used for 0.13.0 compatibility, technically this allocator is completely unused by "writeStackTrace"
    fn getDebugInfoAllocator() std.mem.Allocator {
        return std.heap.page_allocator;
    }

    fn dumpStackTrace(stack_trace: std.builtin.StackTrace) void {
        nosuspend {
            if (comptime builtin.target.isWasm()) {
                if (native_os == .wasi) {
                    const stderr = io.getStdErr().writer();
                    stderr.print("Unable to dump stack trace: not implemented for Wasm\n", .{}) catch return;
                }
                return;
            }
            const stderr = io.getStdErr().writer();
            if (builtin.strip_debug_info) {
                stderr.print("Unable to dump stack trace: debug info stripped\n", .{}) catch return;
                return;
            }
            const debug_info = getSelfDebugInfo() catch |err| {
                stderr.print("Unable to dump stack trace: Unable to open debug info: {s}\n", .{@errorName(err)}) catch return;
                return;
            };
            if (builtin.zig_version.major == 0 and builtin.zig_version.minor == 13) {
                // Legacy 0.13.0
                writeStackTrace(stack_trace, stderr, getDebugInfoAllocator(), debug_info, io.tty.detectConfig(io.getStdErr())) catch |err| {
                    stderr.print("Unable to dump stack trace: {s}\n", .{@errorName(err)}) catch return;
                    return;
                };
            } else {
                // 0.14.0-dev+
                writeStackTrace(stack_trace, stderr, debug_info, io.tty.detectConfig(io.getStdErr())) catch |err| {
                    stderr.print("Unable to dump stack trace: {s}\n", .{@errorName(err)}) catch return;
                    return;
                };
            }
        }
    }

    const writeCurrentStackTrace = std.debug.writeCurrentStackTrace;
    fn dumpCurrentStackTrace(start_addr: ?usize) void {
        nosuspend {
            if (comptime builtin.target.isWasm()) {
                if (native_os == .wasi) {
                    const stderr = io.getStdErr().writer();
                    stderr.print("Unable to dump stack trace: not implemented for Wasm\n", .{}) catch return;
                }
                return;
            }
            const stderr = io.getStdErr().writer();
            if (builtin.strip_debug_info) {
                stderr.print("Unable to dump stack trace: debug info stripped\n", .{}) catch return;
                return;
            }
            const debug_info = getSelfDebugInfo() catch |err| {
                stderr.print("Unable to dump stack trace: Unable to open debug info: {s}\n", .{@errorName(err)}) catch return;
                return;
            };
            writeCurrentStackTrace(stderr, debug_info, io.tty.detectConfig(io.getStdErr()), start_addr) catch |err| {
                stderr.print("Unable to dump stack trace: {s}\n", .{@errorName(err)}) catch return;
                return;
            };
        }
    }
};
