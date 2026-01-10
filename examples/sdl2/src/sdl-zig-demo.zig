const std = @import("std");
const builtin = @import("builtin");
const android = @import("android");
const sdl = @import("sdl");

const log = std.log;
const assert = std.debug.assert;

// custom standard options for Android
pub const std_options: std.Options = if (builtin.abi.isAndroid())
    .{
        .logFn = android.logFn,
    }
else
    .{};

/// custom panic handler for Android
pub const panic = if (builtin.abi.isAndroid() and builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
    android.panic
else
    std.debug.FullPanic(std.debug.defaultPanic);

comptime {
    if (builtin.abi.isAndroid()) {
        @export(&SDL_main, .{ .name = "SDL_main", .linkage = .strong });
    }
}

inline fn wrapMain(result: anytype) u8 {
    // General error message for a malformed return type
    const bad_main_ret = "expected return type of main to be 'void', '!void', 'noreturn', 'u8', or '!u8'";

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
        switch (builtin.os.tag) {
            .freestanding, .other => {},
            else => if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace),
        }
        return 1;
    };

    return switch (@TypeOf(unwrapped_result)) {
        noreturn => unreachable,
        void => 0,
        u8 => unwrapped_result,
        else => @compileError(bad_main_ret),
    };
}

/// This needs to be exported for Android builds
fn SDL_main() callconv(.c) void {
    if (comptime builtin.abi.isAndroid()) {
        _ = wrapMain(main());
    } else {
        @compileError("SDL_main should not be called outside of Android builds");
    }
}

pub fn main() !void {
    log.debug("started sdl-zig-demo", .{});

    if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO) < 0) {
        log.info("Unable to initialize SDL: {s}", .{sdl.SDL_GetError()});
        return error.SDLInitializationFailed;
    }
    defer sdl.SDL_Quit();

    const screen = sdl.SDL_CreateWindow("My Game Window", sdl.SDL_WINDOWPOS_UNDEFINED, sdl.SDL_WINDOWPOS_UNDEFINED, 400, 140, sdl.SDL_WINDOW_OPENGL) orelse {
        log.info("Unable to create window: {s}", .{sdl.SDL_GetError()});
        return error.SDLInitializationFailed;
    };
    defer sdl.SDL_DestroyWindow(screen);

    const renderer = sdl.SDL_CreateRenderer(screen, -1, 0) orelse {
        log.info("Unable to create renderer: {s}", .{sdl.SDL_GetError()});
        return error.SDLInitializationFailed;
    };
    defer sdl.SDL_DestroyRenderer(renderer);

    const zig_bmp = @embedFile("zig.bmp");
    const rw = sdl.SDL_RWFromConstMem(zig_bmp, zig_bmp.len) orelse {
        log.info("Unable to get RWFromConstMem: {s}", .{sdl.SDL_GetError()});
        return error.SDLInitializationFailed;
    };
    defer assert(sdl.SDL_RWclose(rw) == 0);

    const zig_surface = sdl.SDL_LoadBMP_RW(rw, 0) orelse {
        log.info("Unable to load bmp: {s}", .{sdl.SDL_GetError()});
        return error.SDLInitializationFailed;
    };
    defer sdl.SDL_FreeSurface(zig_surface);

    const zig_texture = sdl.SDL_CreateTextureFromSurface(renderer, zig_surface) orelse {
        log.info("Unable to create texture from surface: {s}", .{sdl.SDL_GetError()});
        return error.SDLInitializationFailed;
    };
    defer sdl.SDL_DestroyTexture(zig_texture);

    var quit = false;
    var has_run_frame: FrameLog = .none;
    while (!quit) {
        if (has_run_frame == .one_frame_passed) {
            // NOTE(jae): 2024-10-03
            // Allow inspection of logs to see if a frame executed at least once
            log.debug("has executed one frame", .{});
            has_run_frame = .logged_one_frame;
        }
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                sdl.SDL_QUIT => {
                    quit = true;
                },
                else => {},
            }
        }

        _ = sdl.SDL_RenderClear(renderer);
        _ = sdl.SDL_RenderCopy(renderer, zig_texture, null, null);
        sdl.SDL_RenderPresent(renderer);
        sdl.SDL_Delay(17);
        if (has_run_frame == .none) {
            has_run_frame = .one_frame_passed;
        }
    }
}

const FrameLog = enum {
    none,
    one_frame_passed,
    logged_one_frame,
};
