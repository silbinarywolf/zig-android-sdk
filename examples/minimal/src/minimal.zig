const std = @import("std");
const builtin = @import("builtin");
const android = @import("android");
const androidbind = @import("android-bind.zig");
const log = std.log;

/// custom standard options for Android
pub const std_options: std.Options = if (builtin.abi == .android)
    .{
        .logFn = android.logFn,
    }
else
    .{};

/// custom panic handler for Android
pub const panic = if (builtin.abi == .android)
    android.panic
else
    std.builtin.default_panic;

fn nativeActivityOnCreate(activity: *androidbind.ANativeActivity, savedState: []const u8) !void {
    const sdk_version: c_int = blk: {
        var sdk_ver_str: [92]u8 = undefined;
        const len = androidbind.__system_property_get("ro.build.version.sdk", &sdk_ver_str);
        if (len <= 0) {
            break :blk 0;
        } else {
            const str = sdk_ver_str[0..@intCast(len)];
            break :blk std.fmt.parseInt(c_int, str, 10) catch 0;
        }
    };

    log.debug(
        \\Zig Android SDK:
        \\  App:              {s}
        \\  API level:        actual={d}
        \\  App pid:          {}
        \\  Build mode:       {s}
        \\  ABI:              {s}-{s}-{s}
        \\  Compiler version: {}
        \\  Compiler backend: {s}
    , .{
        "Minimal App", // build_options.app_name,
        // build_options.android_sdk_version,
        sdk_version,
        std.os.linux.getpid(),
        @tagName(builtin.mode),
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        @tagName(builtin.abi),
        builtin.zig_version,
        @tagName(builtin.zig_backend),
    });

    const allocator = std.heap.c_allocator;

    const app = try allocator.create(AndroidApp);
    errdefer allocator.destroy(app);

    activity.callbacks.* = makeNativeActivityGlue(AndroidApp);
    app.* = try AndroidApp.init(
        allocator,
        activity,
        savedState,
    );
    errdefer app.deinit();

    try app.start();

    activity.instance = app;

    log.debug("Successfully started the app.", .{});
}

/// Android entry point
export fn ANativeActivity_onCreate(activity: *androidbind.ANativeActivity, rawSavedState: ?[*]u8, rawSavedStateSize: usize) callconv(.C) void {
    const savedState: []const u8 = if (rawSavedState) |s|
        s[0..rawSavedStateSize]
    else
        &[0]u8{};

    nativeActivityOnCreate(activity, savedState) catch |err| {
        log.err("ANativeActivity_onCreate: error within nativeActivityOnCreate: {s}", .{@errorName(err)});
        return;
    };
}

/// Entry point for our application.
/// This struct provides the interface to the android support package.
pub const AndroidApp = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    activity: *androidbind.ANativeActivity,

    /// This is the entry point which initializes a application
    /// that has stored its previous state.
    /// `stored_state` is that state, the memory is only valid for this function.
    pub fn init(allocator: std.mem.Allocator, activity: *androidbind.ANativeActivity, savedState: []const u8) !Self {
        _ = savedState; // autofix

        return Self{
            .allocator = allocator,
            .activity = activity,
        };
    }

    /// This function is called when the application is successfully initialized.
    /// It should create a background thread that processes the events and runs until
    /// the application gets destroyed.
    pub fn start(self: *Self) !void {
        _ = self;
    }

    /// Uninitialize the application.
    /// Don't forget to stop your background thread here!
    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }
};

/// Returns a wrapper implementation for the given App type which implements all
/// ANativeActivity callbacks.
fn makeNativeActivityGlue(comptime App: type) androidbind.ANativeActivityCallbacks {
    const T = struct {
        fn invoke(activity: *androidbind.ANativeActivity, comptime func: []const u8, args: anytype) void {
            if (!@hasDecl(App, func)) {
                log.debug("ANativeActivity callback {s} not available on {s}", .{ func, @typeName(App) });
                return;
            }
            const instance = activity.instance orelse return;
            const result = @call(.auto, @field(App, func), .{@as(*App, @ptrCast(instance))} ++ args);
            switch (@typeInfo(@TypeOf(result))) {
                .ErrorUnion => result catch |err| log.err("{s} returned error {s}", .{ func, @errorName(err) }),
                .Void => {},
                .ErrorSet => log.err("{s} returned error {s}", .{ func, @errorName(result) }),
                else => @compileError("callback must return void!"),
            }
        }

        // return value must be created with malloc(), so we pass the c_allocator to App.onSaveInstanceState
        fn onSaveInstanceState(activity: *androidbind.ANativeActivity, outSize: *usize) callconv(.C) ?[*]u8 {
            outSize.* = 0;
            if (!@hasDecl(App, "onSaveInstanceState")) {
                log.debug("ANativeActivity callback onSaveInstanceState not available on {s}", .{@typeName(App)});
                return null;
            }
            const instance = activity.instance orelse return null;
            const optional_slice = @as(*App, @ptrCast(instance)).onSaveInstanceState(std.heap.c_allocator);
            if (optional_slice) |slice| {
                outSize.* = slice.len;
                return slice.ptr;
            }
            return null;
        }

        fn onDestroy(activity: *androidbind.ANativeActivity) callconv(.C) void {
            const instance = activity.instance orelse return;
            const app: *App = @ptrCast(@alignCast(instance));
            app.deinit();
            std.heap.c_allocator.destroy(app);
        }
        fn onStart(activity: *androidbind.ANativeActivity) callconv(.C) void {
            invoke(activity, "onStart", .{});
        }
        fn onResume(activity: *androidbind.ANativeActivity) callconv(.C) void {
            invoke(activity, "onResume", .{});
        }
        fn onPause(activity: *androidbind.ANativeActivity) callconv(.C) void {
            invoke(activity, "onPause", .{});
        }
        fn onStop(activity: *androidbind.ANativeActivity) callconv(.C) void {
            invoke(activity, "onStop", .{});
        }
        fn onConfigurationChanged(activity: *androidbind.ANativeActivity) callconv(.C) void {
            invoke(activity, "onConfigurationChanged", .{});
        }
        fn onLowMemory(activity: *androidbind.ANativeActivity) callconv(.C) void {
            invoke(activity, "onLowMemory", .{});
        }
        fn onWindowFocusChanged(activity: *androidbind.ANativeActivity, hasFocus: c_int) callconv(.C) void {
            invoke(activity, "onWindowFocusChanged", .{(hasFocus != 0)});
        }
        fn onNativeWindowCreated(activity: *androidbind.ANativeActivity, window: *androidbind.ANativeWindow) callconv(.C) void {
            invoke(activity, "onNativeWindowCreated", .{window});
        }
        fn onNativeWindowResized(activity: *androidbind.ANativeActivity, window: *androidbind.ANativeWindow) callconv(.C) void {
            invoke(activity, "onNativeWindowResized", .{window});
        }
        fn onNativeWindowRedrawNeeded(activity: *androidbind.ANativeActivity, window: *androidbind.ANativeWindow) callconv(.C) void {
            invoke(activity, "onNativeWindowRedrawNeeded", .{window});
        }
        fn onNativeWindowDestroyed(activity: *androidbind.ANativeActivity, window: *androidbind.ANativeWindow) callconv(.C) void {
            invoke(activity, "onNativeWindowDestroyed", .{window});
        }
        fn onInputQueueCreated(activity: *androidbind.ANativeActivity, input_queue: *androidbind.AInputQueue) callconv(.C) void {
            invoke(activity, "onInputQueueCreated", .{input_queue});
        }
        fn onInputQueueDestroyed(activity: *androidbind.ANativeActivity, input_queue: *androidbind.AInputQueue) callconv(.C) void {
            invoke(activity, "onInputQueueDestroyed", .{input_queue});
        }
        fn onContentRectChanged(activity: *androidbind.ANativeActivity, rect: *const androidbind.ARect) callconv(.C) void {
            invoke(activity, "onContentRectChanged", .{rect});
        }
    };
    return androidbind.ANativeActivityCallbacks{
        .onStart = T.onStart,
        .onResume = T.onResume,
        .onSaveInstanceState = T.onSaveInstanceState,
        .onPause = T.onPause,
        .onStop = T.onStop,
        .onDestroy = T.onDestroy,
        .onWindowFocusChanged = T.onWindowFocusChanged,
        .onNativeWindowCreated = T.onNativeWindowCreated,
        .onNativeWindowResized = T.onNativeWindowResized,
        .onNativeWindowRedrawNeeded = T.onNativeWindowRedrawNeeded,
        .onNativeWindowDestroyed = T.onNativeWindowDestroyed,
        .onInputQueueCreated = T.onInputQueueCreated,
        .onInputQueueDestroyed = T.onInputQueueDestroyed,
        .onContentRectChanged = T.onContentRectChanged,
        .onConfigurationChanged = T.onConfigurationChanged,
        .onLowMemory = T.onLowMemory,
    };
}
