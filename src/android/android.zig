const std = @import("std");
const builtin = @import("builtin");

extern "log" fn __android_log_write(prio: c_int, tag: [*c]const u8, text: [*c]const u8) c_int;

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

    /// Returns a string literal of the given level in full text form.
    pub fn asText(comptime self: Level) []const u8 {
        return switch (self) {
            .err => "error",
            .warn => "warning",
            .info => "info",
            .debug => "debug",
        };
    }
};

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
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

const LogWriter = struct {
    /// name of the application / log scope
    const tag: [*c]const u8 = null; // = "zig-app";

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
            _ = __android_log_write(
                @intFromEnum(self.level),
                null, // tag.ptr,
                &self.line_buffer,
            );
        }
        self.line_len = 0;
    }

    fn writer(self: *@This()) Writer {
        return Writer{ .context = self };
    }
};

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

    fn panicImpl(trace: ?*const std.builtin.StackTrace, first_trace_addr: ?usize, msg: []const u8) noreturn {
        @setCold(true);

        // NOTE(jae): 2024-09-15
        // resetSegfaultHandler is not a public function
        // if (comptime std.options.enable_segfault_handler) {
        //     // If a segfault happens while panicking, we want it to actually segfault, not trigger
        //     // the handler.
        //     std.debug.resetSegfaultHandler();
        // }

        // Note there is similar logic in handleSegfaultPosix and handleSegfaultWindowsExtra.
        nosuspend switch (panic_stage) {
            0 => {
                panic_stage = 1;

                _ = panicking.fetchAdd(1, .seq_cst);

                // Make sure to release the mutex when done
                {
                    panic_mutex.lock();
                    defer panic_mutex.unlock();

                    var logger = LogWriter{
                        .level = .fatal,
                    };
                    const stderr = logger.writer();
                    if (builtin.single_threaded) {
                        stderr.print("panic: ", .{}) catch @trap();
                    } else {
                        const current_thread_id = std.Thread.getCurrentId();
                        stderr.print("thread {} panic: ", .{current_thread_id}) catch @trap();
                    }
                    stderr.print("{s}\n", .{msg}) catch @trap();
                    if (trace) |t| {
                        // std.debug.dumpStackTrace(t.*);
                        if (builtin.strip_debug_info) {
                            stderr.print("Unable to dump stack trace: debug info stripped\n", .{}) catch return;
                        } else {
                            const debug_info = std.debug.getSelfDebugInfo() catch |err| {
                                stderr.print("Unable to dump stack trace: Unable to open debug info: {s}\n", .{@errorName(err)}) catch return;
                                @trap();
                            };
                            var debug_info_arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                            const allocator = debug_info_arena_allocator.allocator();
                            std.debug.writeStackTrace(t.*, stderr, allocator, debug_info, .no_color) catch |err| {
                                stderr.print("Unable to dump stack trace: {s}\n", .{@errorName(err)}) catch return;
                                @trap();
                            };
                        }
                    }
                    // std.debug.dumpCurrentStackTrace(first_trace_addr);
                    {
                        if (builtin.strip_debug_info) {
                            stderr.print("Unable to dump stack trace: debug info stripped\n", .{}) catch return;
                        } else {
                            const debug_info = std.debug.getSelfDebugInfo() catch |err| {
                                stderr.print("Unable to dump stack trace: Unable to open debug info: {s}\n", .{@errorName(err)}) catch return;
                                @trap();
                            };
                            std.debug.writeCurrentStackTrace(stderr, debug_info, .no_color, first_trace_addr) catch |err| {
                                stderr.print("Unable to dump stack trace: {s}\n", .{@errorName(err)}) catch return;
                                @trap();
                            };
                        }
                    }
                }
                // std.debug.waitForOtherThreadToFinishPanicking();
            },
            1 => {
                panic_stage = 2;

                // A panic happened while trying to print a previous panic message,
                // we're still holding the mutex but that's fine as we're going to
                // call abort()
                var logger = LogWriter{
                    .level = .fatal,
                };
                const stderr = logger.writer();
                stderr.print("Panicked during a panic. Aborting.\n", .{}) catch @trap();
            },
            else => {
                // Panicked while printing "Panicked during a panic."
            },
        };

        @trap();
    }
};
