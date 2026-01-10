//! Seperate module for Zig 0.15.2 functionality as @Type() comptime directive was removed

const std = @import("std");

const LogFunction = fn (comptime message_level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void;

pub fn wrapLogFn(comptime logFn: fn (
    comptime message_level: std.log.Level,
    comptime scope_prefix_text: [:0]const u8,
    comptime format: []const u8,
    args: anytype,
) void) LogFunction {
    return struct {
        fn standardLogFn(comptime message_level: std.log.Level, comptime scope: @Type(.enum_literal), comptime format: []const u8, args: anytype) void {
            // NOTE(jae): 2024-09-11
            // Zig has a colon ": " or "): " for scoped but Android logs just do that after being flushed
            // So we don't do that here.
            const scope_prefix_text = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")"; // "): ";
            return logFn(message_level, scope_prefix_text, format, args);
        }
    }.standardLogFn;
}
