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
const log_tag: [:0]const u8 = android_builtin.package_name;

/// Writes the constant string text to the log, with priority prio and tag tag.
/// Returns: 1 if the message was written to the log, or -EPERM if it was not; see __android_log_is_loggable().
/// Source: https://developer.android.com/ndk/reference/group/logging
extern "log" fn __android_log_write(prio: c_int, tag: [*c]const u8, text: [*c]const u8) c_int;

/// Writes a formatted string to the log, with priority prio and tag tag.
/// The details of formatting are the same as for printf(3)
/// Returns: 1 if the message was written to the log, or -EPERM if it was not; see __android_log_is_loggable().
/// Source: https://man7.org/linux/man-pages/man3/printf.3.html
extern "log" fn __android_log_print(prio: c_int, tag: [*c]const u8, text: [*c]const u8, ...) c_int;

/// Alternate panic implementation that calls __android_log_write so that you can see the logging via "adb logcat"
pub const panic = std.debug.FullPanic(Panic.panic);

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
pub const logFn = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 14)
    @import("LogWriter_Zig014.zig").logFn
else
    AndroidLog.logFn;

/// AndroidLog is a Writer interface that logs out to Android via "__android_log_write" calls
const AndroidLog = struct {
    level: Level,
    writer: std.Io.Writer,

    const vtable: std.Io.Writer.VTable = .{
        .drain = @This().drain,
    };

    fn init(level: Level, buffer: []u8) AndroidLog {
        return .{
            .level = level,
            .writer = .{
                .buffer = buffer,
                .vtable = &vtable,
            },
        };
    }

    fn log_each_newline(logger: *AndroidLog, buffer: []const u8) std.Io.Writer.Error!usize {
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
        const logger: *AndroidLog = @alignCast(@fieldParentPtr("writer", w));
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

    fn logFn(
        comptime message_level: std.log.Level,
        comptime scope: @Type(.enum_literal),
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
            _ = __android_log_print(
                @intFromEnum(Level.fatal),
                comptime if (log_tag.len == 0) null else log_tag.ptr,
                "%.*s",
                format.len,
                format.ptr,
            );
            return;
        }

        // NOTE(jae): 2024-09-11
        // Zig has a colon ": " or "): " for scoped but Android logs just do that after being flushed
        // So we don't do that here.
        const prefix2 = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")"; // "): ";

        const android_log_level: Level = switch (message_level) {
            //  => .ANDROID_LOG_VERBOSE, // No mapping
            .debug => .debug, // android.ANDROID_LOG_DEBUG = 3,
            .info => .info, // android.ANDROID_LOG_INFO = 4,
            .warn => .warn, // android.ANDROID_LOG_WARN = 5,
            .err => .err, // android.ANDROID_LOG_WARN = 6,
        };
        var buffer: [8192]u8 = undefined;
        var logger = AndroidLog.init(android_log_level, &buffer);

        nosuspend {
            logger.writer.print(prefix2 ++ format ++ "\n", args) catch return;
            logger.writer.flush() catch return;
        }
    }
};

/// Panic is a copy-paste of the panic logic from Zig but replaces usages of getStdErr with our own writer
///
/// Example output (Zig 0.13.0):
/// 09-22 13:08:49.578  3390  3390 F com.zig.minimal: thread 3390 panic: your panic message here
/// 09-22 13:08:49.637  3390  3390 F com.zig.minimal: zig-android-sdk/examples\minimal/src/minimal.zig:33:15: 0x7ccb77b282dc in nativeActivityOnCreate (minimal)
/// 09-22 13:08:49.637  3390  3390 F com.zig.minimal: zig-android-sdk/examples/minimal/src/minimal.zig:84:27: 0x7ccb77b28650 in ANativeActivity_onCreate (minimal)
/// 09-22 13:08:49.637  3390  3390 F com.zig.minimal: ???:?:?: 0x7ccea4021d9c in ??? (libandroid_runtime.so)
const Panic = struct {
    /// Non-zero whenever the program triggered a panic.
    /// The counter is incremented/decremented atomically.
    var panicking = std.atomic.Value(u8).init(0);

    /// Counts how many times the panic handler is invoked by this thread.
    /// This is used to catch and handle panics triggered by the panic handler.
    threadlocal var panic_stage: usize = 0;

    fn panic(message: []const u8, ret_addr: ?usize) noreturn {
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
            @import("LogWriter_Zig014.zig"){
                .level = .fatal,
            }
        else
            AndroidLog.init(.fatal, &android_log_writer_buffer);

        fn lockAndroidLogWriter() if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 14)
            std.io.GenericWriter(*@import("LogWriter_Zig014.zig"), @import("LogWriter_Zig014.zig").Error, @import("LogWriter_Zig014.zig").write)
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
                        _ = __android_log_print(
                            @intFromEnum(Level.fatal),
                            comptime if (log_tag.len == 0) null else log_tag.ptr,
                            "panic: %.*s",
                            msg.len,
                            msg.ptr,
                        );
                    } else {
                        const current_thread_id: u32 = std.Thread.getCurrentId();
                        _ = __android_log_print(
                            @intFromEnum(Level.fatal),
                            comptime if (log_tag.len == 0) null else log_tag.ptr,
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

        posix.abort();
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
};

fn android_fatal_log(message: [:0]const u8) void {
    _ = __android_log_write(
        @intFromEnum(Level.fatal),
        comptime if (log_tag.len == 0) null else log_tag.ptr,
        message,
    );
}

fn android_fatal_print_c_string(
    comptime fmt: [:0]const u8,
    c_str: [:0]const u8,
) void {
    _ = __android_log_print(
        @intFromEnum(Level.fatal),
        comptime if (log_tag.len == 0) null else log_tag.ptr,
        fmt,
        c_str.ptr,
    );
}

fn android_log_string(android_log_level: Level, text: []const u8) void {
    _ = __android_log_print(
        @intFromEnum(android_log_level),
        comptime if (log_tag.len == 0) null else log_tag.ptr,
        "%.*s",
        text.len,
        text.ptr,
    );
}
