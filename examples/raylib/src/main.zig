const std = @import("std");
const rl = @import("raylib");

//Other than exporting this function and changing the calling convention, you
//can write your code fairly normally.
//
//The main function is not allowed to return zig errors, so you will have to
//use "catch @panic()" or create other error handling functionality.
export fn main() callconv(.C) void {
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
