# Minimal Example

As of 2024-09-19, this is a thrown together, very quick copy-paste of the minimal example from the original [ZigAndroidTemplate](https://github.com/ikskuh/ZigAndroidTemplate/blob/master/examples/minimal/main.zig) repository.

### Build and install to test one target against a local emulator

```sh
zig build -Dtarget=x86_64-linux-android
adb install ./zig-out/bin/minimal.apk
```

### Build and install for all supported Android targets

```sh
zig build -Dandroid=true
adb install ./zig-out/bin/minimal.apk
```

### View logs of application

Powershell
```sh
adb logcat | Select-String com.zig.minimal:
```

Bash
```sh
adb logcat --pid=`adb shell pidof -s com.zig.minimal`
```
