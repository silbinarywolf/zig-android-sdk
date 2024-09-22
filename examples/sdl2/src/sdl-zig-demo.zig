const std = @import("std");
const builtin = @import("builtin");
const android = @import("android");
const sdl = @import("sdl");

const log = std.log;
const assert = std.debug.assert;

/// custom standard options for Android
pub const std_options: std.Options = if (builtin.abi == .android)
    .{
        .logFn = android.logFn,
    }
else
    .{};

/// custom panic handler for Android
pub const panic = if (builtin.abi == .android)
    android.panic
else
    std.builtin.default_panic;

/// This needs to be exported for Android builds
export fn SDL_main() callconv(.C) void {
    if (builtin.abi == .android) {
        android.set_default_tag("com.zig.sdl2");
        _ = std.start.callMain();
    } else {
        @panic("SDL_main should not be called outside of Android builds");
    }
}

pub fn main() !void {
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
    while (!quit) {
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
    }
}
