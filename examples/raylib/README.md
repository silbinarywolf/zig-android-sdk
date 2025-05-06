A minimal example of using [zig-android-sdk](https://github.com/silbinarywolf/zig-android-sdk) to build raylib for android.

Build for a single target with, e.g. `zig build -Dtarget=aarch64-linux-android`, or for all android targets with `zig build -Dandroid=true`.

**Note**:
Due to [an upstream bug](https://github.com/ziglang/zig/issues/20476), you will probably receive a warning (or multiple warnings if building for multiple targets) like this:
```
error: warning(link): unexpected LLD stderr:
ld.lld: warning: <path-to-project>/.zig-cache/o/4227869d730f094811a7cdaaab535797/libraylib.a: archive member '<path-to-ndk>/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/x86_64-linux-android/35/libGLESv2.so' is neither ET_REL nor LLVM bitcode
```
You can ignore this error for now.

You should probably source the `android_native_app_glue.c/.h` files from the version of the SDK you download, rather than using the included ones, to ensure you are using the most up-to-date versions.


