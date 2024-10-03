const std = @import("std");
const androidbuild = @import("androidbuild.zig");
const builtin = @import("builtin");
const Build = std.Build;
const Step = Build.Step;
const Options = Build.Step.Options;
const LazyPath = Build.LazyPath;
const fs = std.fs;
const mem = std.mem;
const assert = std.debug.assert;

/// BuiltinOptionsUpdate will update the *Options
pub const BuiltinOptionsUpdate = struct {
    pub const base_id: Step.Id = .custom;

    step: Step,

    options: *Options,
    package_name_stdout: LazyPath,

    pub fn create(owner: *std.Build, options: *Options, package_name_stdout: LazyPath) void {
        const builtin_options_update = owner.allocator.create(@This()) catch @panic("OOM");
        builtin_options_update.* = .{
            .step = Step.init(.{
                .id = base_id,
                .name = androidbuild.runNameContext("builtin_options_update"),
                .owner = owner,
                .makeFn = comptime if (std.mem.eql(u8, builtin.zig_version_string, "0.13.0"))
                    make013
                else
                    makeLatest,
            }),
            .options = options,
            .package_name_stdout = package_name_stdout,
        };
        // Run step relies on this finishing
        options.step.dependOn(&builtin_options_update.step);
        // Depend on package name stdout before running this step
        package_name_stdout.addStepDependencies(&builtin_options_update.step);
    }

    /// make for zig 0.13.0
    fn make013(step: *Step, prog_node: std.Progress.Node) !void {
        _ = prog_node; // autofix
        try make(step);
    }

    /// make for zig 0.14.0+
    fn makeLatest(step: *Step, options: Build.Step.MakeOptions) !void {
        _ = options; // autofix
        try make(step);
    }

    fn make(step: *Step) !void {
        const b = step.owner;
        const builtin_options_update: *@This() = @fieldParentPtr("step", step);
        const options = builtin_options_update.options;

        const package_name_path = builtin_options_update.package_name_stdout.getPath2(b, step);

        const file = try fs.openFileAbsolute(package_name_path, .{});

        // Read package name from stdout and strip line feed / carriage return
        // ie. "com.zig.sdl2\n\r"
        const package_name_filedata = try file.readToEndAlloc(b.allocator, 8192);
        const package_name_stripped = std.mem.trimRight(u8, package_name_filedata, " \r\n");
        const package_name: [:0]const u8 = try b.allocator.dupeZ(u8, package_name_stripped);

        options.addOption([:0]const u8, "package_name", package_name);
    }
};
