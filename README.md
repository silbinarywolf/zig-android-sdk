# <img src="examples/minimal/android/res/mipmap/ic_launcher.png" width="32" height="32"> Zig Android SDK

![Continuous integration](https://github.com/silbinarywolf/zig-android-sdk/actions/workflows/ci.yml/badge.svg)

⚠️ **WARNING:** This is a work-in-progress and will be updated as I improve it for my personal SDL2 / OpenXR project.

This library allows you to setup and build an APK for your Android devices. This project was mostly based off the work of [ikskuh](https://github.com/ikskuh) and wouldn't exist with their previous work on their [ZigAndroidTemplate](https://github.com/ikskuh/ZigAndroidTemplate) project.

```zig
// Look at "examples/minimal/build.zig"

const android = @import("zig-android-sdk");

pub fn build(b: *std.Build) !void {
    const android_tools = android.Tools.create(b, ...);
    const apk = android.APK.create(b, android_tools);
    apk.setAndroidManifest(b.path("android/AndroidManifest.xml"));
    apk.addResourceDirectory(b.path("android/res"));
    apk.addJavaSourceFile(.{ .file = b.path("android/src/NativeInvocationHandler.java") });
    apk.addArtifact(b.addSharedLibrary(.{
        .name = exe_name,
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }))
}
```

## Requirements

* [Zig](https://ziglang.org/download)
* Android Tools
    * Option A: [Android Studio](https://developer.android.com/studio)
    * Option B: [Android Command Line Tools](https://developer.android.com/studio#command-line-tools-only)


## Installation

Add the following to your build.zig.zon file, see [examples/minimal/build.zig](examples/minimal/build.zig) for how to use it.

```zig
.{
    .dependencies = .{
        .@"zig-android-sdk" = .{
            .path = "https://github.com/zigimg/zigimg/archive/REPLACE_WITH_WANTED_COMMIT.tar.gz",
            // .hash = REPLACE_WITH_HASH_FROM_BUILD_ERROR
        },
    },
}
```

## Examples

* [minimal](examples/minimal): This is based off [ZigAndroidTemplate's minimal](https://github.com/ikskuh/ZigAndroidTemplate/tree/master/examples/minimal) example.

## Credits

- [ikskuh](https://github.com/ikskuh) This would not exist without their [ZigAndroidTemplate](https://github.com/ikskuh/ZigAndroidTemplate) repository to use as a baseline for figuring this all out and also being able to use their logic for the custom panic / logging functions.
    - ikskuh gave a huge thanks [https://github.com/cnlohr] for [rawdrawandroid](https://github.com/cnlohr/rawdrawandroid) and so I thank them as well by proxy
