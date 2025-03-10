# <img src="examples/minimal/android/res/mipmap/ic_launcher.png" width="32" height="32"> Zig Android SDK

![Continuous integration](https://github.com/silbinarywolf/zig-android-sdk/actions/workflows/ci.yml/badge.svg)

This library allows you to setup and build an APK for your Android devices. This project was mostly based off the work of [ikskuh](https://github.com/ikskuh) and wouldn't exist without the work they did on the [ZigAndroidTemplate](https://github.com/ikskuh/ZigAndroidTemplate) project.


```sh
# Target one Android architecture
zig build -Dtarget=x86_64-linux-android

# Target all Android architectures
zig build -Dandroid=true
```

```zig
// This is an overly simplified example to give you the gist
// of how this library works, see: examples/minimal/build.zig
const android = @import("android");

pub fn build(b: *std.Build) !void {
    const android_tools = android.Tools.create(b, ...);
    const apk = android.APK.create(b, android_tools);
    apk.setAndroidManifest(b.path("android/AndroidManifest.xml"));
    apk.addResourceDirectory(b.path("android/res"));
    apk.addJavaSourceFile(.{ .file = b.path("android/src/NativeInvocationHandler.java") });
    for (android.standardTargets(b, b.standardTargetOptions(.{}))) |target| {
        apk.addArtifact(b.addSharedLibrary(.{
            .name = exe_name,
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }))
    }
}
```

## Requirements

* [Zig](https://ziglang.org/download)
* Android Tools
    * Option A: [Android Studio](https://developer.android.com/studio)
    * Option B: [Android Command Line Tools](https://developer.android.com/studio#command-line-tools-only)
* [Java Development Kit](https://www.oracle.com/au/java/technologies/downloads/)

## Installation

Add the following to your build.zig.zon file and run `zig build`.

```zig
.{
    .dependencies = .{
        .android = .{
            .path = "https://github.com/silbinarywolf/zig-android-sdk/archive/REPLACE_WITH_WANTED_COMMIT.tar.gz",
            // .hash = REPLACE_WITH_HASH_FROM_BUILD_ERROR
        },
    },
}
```

## Examples

* [minimal](examples/minimal): This is based off ZigAndroidTemplate's minimal example.
* [SDL2](examples/sdl2): This is based off Andrew Kelly's SDL Zig Demo but modified to run on Android, Windows, Mac and Linux.

## Credits

- [ikskuh](https://github.com/ikskuh) This would not exist without their [ZigAndroidTemplate](https://github.com/ikskuh/ZigAndroidTemplate) repository to use as a baseline for figuring this all out and also being able to use their logic for the custom panic / logging functions.
    - ikskuh gave a huge thanks to [@cnlohr](https://github.com/cnlohr) for [rawdrawandroid](https://github.com/cnlohr/rawdrawandroid)
