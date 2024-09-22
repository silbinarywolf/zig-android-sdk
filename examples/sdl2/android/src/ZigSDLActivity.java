package com.zig.sdl2; // <- Your game package name

import org.libsdl.app.SDLActivity;

/**
 * A sample wrapper class that just calls SDLActivity
 */
public class ZigSDLActivity extends SDLActivity {
    @Override
    protected String[] getLibraries() {
        return new String[] {
            // "hidapi", // Built into source of "SDL2"
            "SDL2",
            // "SDL2_image",
            // "SDL2_mixer",
            // "SDL2_net",
            // "SDL2_ttf",
            "main"
        };
    }
}