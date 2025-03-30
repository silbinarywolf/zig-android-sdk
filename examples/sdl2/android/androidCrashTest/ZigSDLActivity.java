package com.zig.sdl2; // <- Your game package name

import org.libsdl.app.SDLActivity;
import android.os.Bundle;
import android.util.AndroidRuntimeException;

/**
 * A sample wrapper class that just calls SDLActivity
 * 
 * Used for testing only to detect if it crashes
 */
public class ZigSDLActivity extends SDLActivity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        if (mBrokenLibraries) {
            throw new AndroidRuntimeException("SDL Error, has broken libraries");
        }
    }
}