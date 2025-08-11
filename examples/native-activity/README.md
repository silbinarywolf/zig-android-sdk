# NativeActivity

Ported from https://github.com/android/ndk-samples/tree/main/native-activity .

This example demonstrates the use of native_app_glue and android_main.

## std.log override

```zig
_ = c.__android_log_write(priority, "ZIG", &buf.buffer);
```

You can display the logs filtered by "ZIG" in color by following the steps below.

```
$ adb logcat -s "ZIG" -v color
```
