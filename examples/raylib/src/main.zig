const std = @import("std");
const builtin = @import("builtin");
const android = @import("android");
const rl = @import("raylib");

pub fn main() void {
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

/// custom panic handler for Android
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
        // Setup exported C-function as defined in AndroidManifest.xml
        // ie. <meta-data android:name="android.app.lib_name" android:value="main"/>
        @export(&androidMain, .{ .name = "main" });
    }
}

fn androidMain() callconv(.c) c_int {
    return std.start.callMain();
}
