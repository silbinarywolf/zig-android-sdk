const std = @import("std");
const builtin = @import("builtin");

const android = @import("android");
const rl = @import("raylib");

pub fn main() !void {
    const screenWidth = 800;
    const screenHeight = 450;

    rl.initWindow(screenWidth, screenHeight, "raylib-zig [core] example - basic window");
    defer rl.closeWindow();

    const zig_tex = try rl.loadTexture("zig.bmp");
    defer rl.unloadTexture(zig_tex);

    rl.setTargetFPS(60);
    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.white);

        rl.drawTexture(zig_tex, screenWidth / 2 - @divTrunc(zig_tex.width, 2), screenHeight / 2, .white);

        rl.drawText("Congrats! You created your first window!", 190, 200, 20, .light_gray);
    }
}

/// Custom panic handler for Android
pub const panic = if (builtin.abi.isAndroid())
    android.panic
else
    std.debug.FullPanic(std.debug.defaultPanic);

/// custom standard options for Android
pub const std_options: std.Options = if (builtin.abi.isAndroid())
    .{
        .logFn = android.logFn,
    }
else
    .{};

comptime {
    if (builtin.abi.isAndroid()) {
        // Setup exported C-function as defined in AndroidManifest.xml and Raylib.
        //
        // Android knows to natively call this library
        // - <meta-data android:name="android.app.lib_name" android:value="main"/>
        //
        // Then Raylib makes the "android_main" entrypoint call the exported "main" C-function
        // https://github.com/raysan5/raylib/blob/f89d38b086c1d0a0c7e38c9c648aa91c05646300/src/platforms/rcore_android.c#L322
        @export(&RaylibAndroidGlue.androidMain, .{ .name = "main" });

        // NOTE(jae): 2026-04-12
        // As of March 2026, Raylib requires a linker flag to make __real_fopen and needs to override "fopen" to call "__wrap_fopen" (provided by Raylib)
        // https://github.com/raysan5/raylib/pull/5624
        //
        // Because Zig doesn't give access to linker flags to add (-Wl,--wrap=fopen), we just export __real_fopen ourselves and call it here:
        // -Wl,--wrap=fopen
        // Related comment: https://github.com/raysan5/raylib/blob/f89d38b086c1d0a0c7e38c9c648aa91c05646300/src/platforms/rcore_android.c#L299-L300
        //
        // Borrowed fix from @maiconpintoabreu:
        // https://gist.github.com/maiconpintoabreu/f5eb68d467ba6105256daf03e3ede51c
        @export(&RaylibAndroidGlue.fopen, .{ .name = "fopen" });
        @export(&RaylibAndroidGlue.__real_fopen, .{ .name = "__real_fopen" });
    }
}

const RaylibAndroidGlue = struct {
    /// General error message for a malformed return type
    const bad_main_ret = "expected return type of main to be 'void', '!void', 'noreturn', 'u8', or '!u8'";

    fn androidMain() callconv(.c) c_int {
        const result = main();
        const ReturnType = @TypeOf(result);
        switch (ReturnType) {
            void => return 0,
            noreturn => unreachable,
            u8 => return result,
            else => {},
        }
        if (@typeInfo(ReturnType) != .error_union) @compileError(bad_main_ret);

        const unwrapped_result = result catch |err| {
            std.log.err("{t}", .{err});
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            return 1;
        };

        return switch (@TypeOf(unwrapped_result)) {
            noreturn => unreachable,
            void => 0,
            u8 => unwrapped_result,
            else => @compileError(bad_main_ret),
        };
    }

    /// Override fopen to call __wrap_fopen (provided by Raylib to load asset files)
    fn fopen(filename: [*c]const u8, modes: [*c]const u8) callconv(.c) ?*anyopaque {
        return __wrap_fopen(filename, modes);
    }

    /// Must implement __real_fopen as Raylib needs it to open files that are not inside assets folder
    fn __real_fopen(filename: [*c]const u8, modes: [*c]const u8) callconv(.c) ?*anyopaque {
        const RTLD_NEXT = @as(?*anyopaque, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))));
        const c_fopen_ptr = RaylibAndroidGlue.dlsym(RTLD_NEXT, "fopen") orelse return null;
        const c_fopen: *const fn ([*c]const u8, [*c]const u8) callconv(.c) ?*anyopaque = @ptrCast(@alignCast(c_fopen_ptr));

        return c_fopen(filename, modes);
    }

    extern "c" fn __wrap_fopen(filename: [*c]const u8, modes: [*c]const u8) callconv(.c) ?*anyopaque;

    // Zig version used to write was 0.16.0
    // Define dlsym and RTLD_NEXT to be able to call system fopen as I am overriding it bellow
    // https://pubs.opengroup.org/onlinepubs/009604299/functions/dlsym.html
    extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*c]const u8) callconv(.c) ?*anyopaque;
};
