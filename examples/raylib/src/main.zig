const std = @import("std");
const builtin = @import("builtin");

const android = @import("android");
const rl = @import("raylib");

pub fn main() !void {
    const screenWidth = 800;
    const screenHeight = 450;
    rl.initWindow(screenWidth, screenHeight, "raylib-zig [core] example - basic window");
    defer rl.closeWindow();
    rl.setTargetFPS(60);
    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.white);

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
        @export(&androidMain, .{ .name = "main" });
    }
}

fn androidMain() callconv(.c) c_int {
    main() catch |err| {
        std.log.err("{t}", .{err});
        if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace);
        return 1;
    };
    return 0;
}
