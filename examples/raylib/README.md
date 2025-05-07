# Raylib Example
**Note**:
Due to [an upstream bug](https://github.com/ziglang/zig/issues/20476), you will probably receive a warning (or multiple warnings if building for multiple targets) like this:
```
error: warning(link): unexpected LLD stderr:
ld.lld: warning: <path-to-project>/.zig-cache/o/4227869d730f094811a7cdaaab535797/libraylib.a: archive member '<path-to-ndk>/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/x86_64-linux-android/35/libGLESv2.so' is neither ET_REL nor LLVM bitcode
```
You can ignore this error for now.

### Build, install to test one target against a local emulator and run

```sh
zig build -Dtarget=x86_64-linux-android
adb install ./zig-out/bin/raylib.apk
adb shell am start -S -W -n com.zig.raylib/android.app.NativeActivity
```

### Build and install for all supported Android targets

```sh
zig build -Dandroid=true
adb install ./zig-out/bin/raylib.apk
```

### Build and run natively on your operating system

```sh
zig build run
```

### Uninstall your application

If installing your application fails with something like:
```
adb: failed to install ./zig-out/bin/raylib.apk: Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package com.zig.raylib signatures do not match newer version; ignoring!]
```

```sh
adb uninstall "com.zig.raylib"
```

### View logs of application

Powershell (app doesn't need to be running)
```sh
adb logcat | Select-String com.zig.raylib:
```

Bash (app doesn't need running to be running)
```sh
adb logcat com.zig.raylib:D *:S
```

Bash (app must be running, logs everything by the process including modules)
```sh
adb logcat --pid=`adb shell pidof -s com.zig.raylib`
```


