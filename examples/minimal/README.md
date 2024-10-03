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

### Uninstall your application

If installing your application fails with something like:
```
adb: failed to install ./zig-out/bin/minimal.apk: Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package com.zig.minimal signatures do not match newer version; ignoring!]
```

```sh
adb uninstall "com.zig.minimal"
```

### View logs of application

Powershell (app doesn't need to be running)
```sh
adb logcat | Select-String com.zig.minimal:
```

Bash (app doesn't need running to be running)
```sh
adb logcat com.zig.minimal:D *:S
```

Bash (app must be running, logs everything by the process including modules)
```sh
adb logcat --pid=`adb shell pidof -s com.zig.minimal`
```
