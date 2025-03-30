package com.zig.sdl2; // <- Your game package name

import org.libsdl.app.SDLActivity;
import android.os.Bundle;
import android.util.AndroidRuntimeException;

/**
 * Used by ci.yml to make the application crash if an error occurs initializing your application.
 * 
 * This allows the following commands to catch crash errors on startup:
 * - adb install ./zig-out/bin/sdl-zig-demo.apk
 * - adb shell monkey --kill-process-after-error --monitor-native-crashes --pct-touch 100 -p com.zig.sdl2 -v 50
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