const std = @import("std");
const c = @import("c.zig");

extern fn call_souce_process(state: *c.android_app, s: *c.android_poll_source) void;
extern fn get_acceleration(event: *const c.ASensorEvent) [*]const f32;

// https://ziggit.dev/t/set-debug-level-at-runtime/6196/3
pub const std_options: std.Options = .{
    .logFn = logFn,
    .log_level = .debug,
};

fn CHECK_NOT_NULL(p: ?*const anyopaque) void {
    if (p == null) {
        @panic("null !");
    }
}

// https://github.com/vamolessa/zig-sdl-android-template/blob/master/src/android_main.zig
// make the std.log.<logger> functions write to the android log
pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const priority = switch (message_level) {
        .err => c.ANDROID_LOG_ERROR,
        .warn => c.ANDROID_LOG_WARN,
        .info => c.ANDROID_LOG_INFO,
        .debug => c.ANDROID_LOG_DEBUG,
    };
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ "): ";

    var buf = std.io.FixedBufferStream([4 * 1024]u8){
        .buffer = undefined,
        .pos = 0,
    };
    var writer = buf.writer();
    writer.print(prefix ++ format, args) catch {};

    if (buf.pos >= buf.buffer.len) {
        buf.pos = buf.buffer.len - 1;
    }
    buf.buffer[buf.pos] = 0;

    _ = c.__android_log_write(priority, "ZIG", &buf.buffer);
}

// for log message @tagName
const AppCmd = enum(c_int) {
    APP_CMD_INPUT_CHANGED = c.APP_CMD_INPUT_CHANGED,
    APP_CMD_INIT_WINDOW = c.APP_CMD_INIT_WINDOW,
    APP_CMD_TERM_WINDOW = c.APP_CMD_TERM_WINDOW,
    APP_CMD_WINDOW_RESIZED = c.APP_CMD_WINDOW_RESIZED,
    APP_CMD_WINDOW_REDRAW_NEEDED = c.APP_CMD_WINDOW_REDRAW_NEEDED,
    APP_CMD_CONTENT_RECT_CHANGED = c.APP_CMD_CONTENT_RECT_CHANGED,
    APP_CMD_GAINED_FOCUS = c.APP_CMD_GAINED_FOCUS,
    APP_CMD_LOST_FOCUS = c.APP_CMD_LOST_FOCUS,
    APP_CMD_CONFIG_CHANGED = c.APP_CMD_CONFIG_CHANGED,
    APP_CMD_LOW_MEMORY = c.APP_CMD_LOW_MEMORY,
    APP_CMD_START = c.APP_CMD_START,
    APP_CMD_RESUME = c.APP_CMD_RESUME,
    APP_CMD_SAVE_STATE = c.APP_CMD_SAVE_STATE,
    APP_CMD_PAUSE = c.APP_CMD_PAUSE,
    APP_CMD_STOP = c.APP_CMD_STOP,
    APP_CMD_DESTROY = c.APP_CMD_DESTROY,
};

const SavedState = struct {
    angle: f32 = 0,
    x: i32 = 0,
    y: i32 = 0,
};

const Engine = struct {
    app: *c.android_app,

    sensorManager: ?*c.ASensorManager = null,
    accelerometerSensor: ?*const c.ASensor = null,
    sensorEventQueue: ?*c.ASensorEventQueue = null,

    display: c.EGLDisplay = null,
    surface: c.EGLSurface = null,
    context: c.EGLContext = null,
    width: i32 = 0,
    height: i32 = 0,
    state: SavedState = .{},

    running_: bool = false,

    fn CreateSensorListener(self: *@This(), callback: c.ALooper_callbackFunc) void {
        std.log.info("  Engine.CreateSensorListener()", .{});
        CHECK_NOT_NULL(self.app);

        self.sensorManager = c.ASensorManager_getInstance();
        if (self.sensorManager == null) {
            return;
        }

        self.accelerometerSensor = c.ASensorManager_getDefaultSensor(
            self.sensorManager,
            c.ASENSOR_TYPE_ACCELEROMETER,
        );
        self.sensorEventQueue = c.ASensorManager_createEventQueue(
            self.sensorManager,
            self.app.looper,
            c.ALOOPER_POLL_CALLBACK,
            callback,
            self,
        );
    }

    /// Resumes ticking the application.
    fn Resume(self: *@This()) void {
        std.log.info("  Engine.Resume()", .{});
        // Checked to make sure we don't double schedule Choreographer.
        if (!self.running_) {
            std.log.info("  start tick", .{});
            self.running_ = true;
            self.ScheduleNextTick();
        }
    }

    fn Pause(self: *@This()) void {
        std.log.info("  Engine.Pause()", .{});
        self.running_ = false;
    }

    fn ScheduleNextTick(self: *@This()) void {
        c.AChoreographer_postFrameCallback(c.AChoreographer_getInstance(), &Tick, self);
    }

    fn Tick(_: c_long, data: ?*anyopaque) callconv(.C) void {
        CHECK_NOT_NULL(data);
        const engine: *Engine = @ptrCast(@alignCast(data));
        engine.DoTick();
    }

    fn DoTick(self: *@This()) void {
        if (!self.running_) {
            return;
        }

        // Input and sensor feedback is handled via their own callbacks.
        // Choreographer ensures that those callbacks run before this callback does.

        // Choreographer does not continuously schedule the callback. We have to re-
        // register the callback each time we're ticked.
        self.ScheduleNextTick();
        self.Update();
        self.DrawFrame();
    }

    fn Update(self: *@This()) void {
        self.state.angle += 0.01;
        if (self.state.angle > 1) {
            self.state.angle = 0;
        }
    }

    fn DrawFrame(self: *@This()) void {
        if (self.display == null) {
            // No display.
            return;
        }

        // Just fill the screen with a color.
        c.glClearColor(
            @as(f32, @floatFromInt(self.state.x)) / @as(f32, @floatFromInt(self.width)),
            self.state.angle,
            @as(f32, @floatFromInt(self.state.y)) / @as(f32, @floatFromInt(self.height)),
            1,
        );
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        _ = c.eglSwapBuffers(self.display, self.surface);
    }
};

fn getEglConfig(display: c.EGLDisplay) ?c.EGLConfig {
    const attribs = [_]c.EGLint{
        c.EGL_SURFACE_TYPE,
        c.EGL_WINDOW_BIT,
        c.EGL_BLUE_SIZE,
        8,
        c.EGL_GREEN_SIZE,
        8,
        c.EGL_RED_SIZE,
        8,
        c.EGL_NONE,
    };
    var numConfigs: c.EGLint = undefined;
    if (c.eglChooseConfig(display, &attribs, null, 0, &numConfigs) != c.EGL_TRUE) {
        return null;
    }
    if (numConfigs == 0) {
        std.log.err("  zero config", .{});
        return null;
    }

    const supportedConfigs = std.heap.page_allocator.alloc(c.EGLConfig, @intCast(numConfigs)) catch @panic("OOP");
    defer std.heap.page_allocator.free(supportedConfigs);
    if (c.eglChooseConfig(display, &attribs, &supportedConfigs[0], numConfigs, &numConfigs) != c.EGL_TRUE) {
        return null;
    }

    for (supportedConfigs) |cfg| {
        var r: c.EGLint = undefined;
        var g: c.EGLint = undefined;
        var b: c.EGLint = undefined;
        var d: c.EGLint = undefined;
        if (c.eglGetConfigAttrib(display, cfg, c.EGL_RED_SIZE, &r) != 0 and
            c.eglGetConfigAttrib(display, cfg, c.EGL_GREEN_SIZE, &g) != 0 and
            c.eglGetConfigAttrib(display, cfg, c.EGL_BLUE_SIZE, &b) != 0 and
            c.eglGetConfigAttrib(display, cfg, c.EGL_DEPTH_SIZE, &d) != 0 and r == 8 and
            g == 8 and b == 8 and d == 0)
        {
            return cfg;
        }
    }
    std.log.warn("  config not found. use first.", .{});
    return supportedConfigs[0];
}

fn engine_init_display(engine: *Engine, window: *c.ANativeWindow) void {
    // initialize OpenGL ES and EGL
    std.log.info("  engine_init_display", .{});

    const display = c.eglGetDisplay(c.EGL_DEFAULT_DISPLAY);
    std.log.debug("  display: {?}", .{display});
    std.debug.assert(c.EGL_TRUE == c.eglInitialize(display, null, null));

    const config = getEglConfig(display) orelse @panic("Unable to initialize EGLConfig");

    var format: c.EGLint = undefined;
    _ = c.eglGetConfigAttrib(display, config, c.EGL_NATIVE_VISUAL_ID, &format);
    const surface = c.eglCreateWindowSurface(display, config, window, null);
    const context = c.eglCreateContext(display, config, null, null);
    if (c.eglMakeCurrent(display, surface, surface, context) == c.EGL_FALSE) {
        @panic("Unable to eglMakeCurrent");
    }

    var w: c.EGLint = undefined;
    _ = c.eglQuerySurface(display, surface, c.EGL_WIDTH, &w);
    var h: c.EGLint = undefined;
    _ = c.eglQuerySurface(display, surface, c.EGL_HEIGHT, &h);

    engine.display = display;
    engine.context = context;
    engine.surface = surface;
    engine.width = w;
    engine.height = h;
    engine.state.angle = 0;

    // Check openGL on the system
    const opengl_info = [4]c.GLenum{ c.GL_VENDOR, c.GL_RENDERER, c.GL_VERSION, c.GL_EXTENSIONS };
    for (opengl_info) |name| {
        const info = c.glGetString(name);
        std.log.info("OpenGL Info: {s}", .{info});
    }
    // Initialize GL state.
    c.glHint(c.GL_PERSPECTIVE_CORRECTION_HINT, c.GL_FASTEST);
    c.glEnable(c.GL_CULL_FACE);
    c.glShadeModel(c.GL_SMOOTH);
    c.glDisable(c.GL_DEPTH_TEST);
}

fn engine_term_display(engine: *Engine) void {
    std.log.info("  engine_term_display", .{});
    if (engine.display != c.EGL_NO_DISPLAY) {
        _ = c.eglMakeCurrent(engine.display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
        if (engine.context != c.EGL_NO_CONTEXT) {
            _ = c.eglDestroyContext(engine.display, engine.context);
        }
        if (engine.surface != c.EGL_NO_SURFACE) {
            _ = c.eglDestroySurface(engine.display, engine.surface);
        }
        _ = c.eglTerminate(engine.display);
    }
    engine.Pause();
    engine.display = c.EGL_NO_DISPLAY;
    engine.context = c.EGL_NO_CONTEXT;
    engine.surface = c.EGL_NO_SURFACE;
}

fn engine_handle_input(app: [*c]c.android_app, event: ?*c.AInputEvent) callconv(.C) i32 {
    const t = c.AInputEvent_getType(event);
    std.log.debug("engine_handle_input: event = {}", .{t});
    var engine: *Engine = @ptrCast(@alignCast(app[0].userData));
    if (t == c.AINPUT_EVENT_TYPE_MOTION) {
        engine.state.x = @intFromFloat(c.AMotionEvent_getX(event, 0));
        engine.state.y = @intFromFloat(c.AMotionEvent_getY(event, 0));
        return 1;
    }
    return 0;
}

fn engine_handle_cmd(app: [*c]c.android_app, _cmd: i32) callconv(.C) void {
    const cmd: AppCmd = @enumFromInt(_cmd);
    std.log.debug("engine_handle_cmd: cmd = {s}", .{@tagName(cmd)});
    const engine: *Engine = @ptrCast(@alignCast(app[0].userData));
    switch (cmd) {
        .APP_CMD_SAVE_STATE => {
            // The system has asked us to save our current state.  Do so.
            engine.app.savedState = std.heap.page_allocator.create(SavedState) catch @panic("OOP");
            @as(*SavedState, @ptrCast(@alignCast(engine.app.savedState))).* = engine.state;
            engine.app.savedStateSize = @sizeOf(SavedState);
        },
        .APP_CMD_INIT_WINDOW => {
            // The window is being shown, get it ready.
            if (engine.app.window) |window| {
                engine_init_display(engine, window);
            }
        },
        .APP_CMD_TERM_WINDOW => {
            // The window is being hidden or closed, clean it up.
            engine_term_display(engine);
        },
        .APP_CMD_GAINED_FOCUS => {
            // When our app gains focus, we start monitoring the accelerometer.
            if (engine.accelerometerSensor != null) {
                _ = c.ASensorEventQueue_enableSensor(engine.sensorEventQueue, engine.accelerometerSensor);
                // We'd like to get 60 events per second (in us).
                _ = c.ASensorEventQueue_setEventRate(engine.sensorEventQueue, engine.accelerometerSensor, (1000 / 60) * 1000);
            }
            engine.Resume();
        },
        .APP_CMD_LOST_FOCUS => {
            // When our app loses focus, we stop monitoring the accelerometer.
            // This is to avoid consuming battery while not being used.
            if (engine.accelerometerSensor != null) {
                _ = c.ASensorEventQueue_disableSensor(engine.sensorEventQueue, engine.accelerometerSensor);
            }
            engine.Pause();
        },
        else => {},
    }
}

fn OnSensorEvent(fd: c_int, events: c_int, data: ?*anyopaque) callconv(.C) i32 {
    _ = fd;
    _ = events;

    CHECK_NOT_NULL(data);
    const engine: *Engine = @ptrCast(@alignCast(data));

    CHECK_NOT_NULL(engine.accelerometerSensor);
    var event: c.ASensorEvent = undefined;
    while (c.ASensorEventQueue_getEvents(engine.sensorEventQueue, &event, 1) > 0) {
        // extern union ?
        // const acceleration: [*]const f32 = get_acceleration(&event);
        // std.log.debug(
        //     "accelerometer: x={} y={} z={}",
        //     .{
        //         acceleration[0],
        //         acceleration[1],
        //         acceleration[2],
        //     },
        // );
    }

    // From the docs:

    // Implementations should return 1 to continue receiving callbacks, or 0 to
    // have this file descriptor and callback unregistered from the looper.
    return 1;
}

export fn android_main(state: *c.android_app) callconv(.C) void {
    std.log.info("#### android_main ####", .{});

    var engine = Engine{
        .app = state,
    };

    state.userData = &engine;
    state.onAppCmd = &engine_handle_cmd;
    state.onInputEvent = &engine_handle_input;

    // Prepare to monitor accelerometer
    engine.CreateSensorListener(&OnSensorEvent);

    if (state.savedState != null) {
        // We are starting with a previous saved state; restore from it.
        engine.state = @as(*SavedState, @ptrCast(@alignCast(state.savedState.?))).*;
    }

    while (state.destroyRequested == 0) {
        // Our input, sensor, and update/render logic is all driven by callbacks, so
        // we don't need to use the non-blocking poll.
        var source: ?*c.android_poll_source = null;
        const result = c.ALooper_pollOnce(-1, null, null, @ptrCast(&source));
        if (result == c.ALOOPER_POLL_ERROR) {
            @panic("ALooper_pollOnce returned an error");
        }

        if (source) |s| {
            call_souce_process(state, s);
        }
    }

    engine_term_display(&engine);
}
