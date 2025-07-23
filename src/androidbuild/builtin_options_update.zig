//! BuiltinOptionsUpdate will update the *Options

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

pub const base_id: Step.Id = .custom;

step: Step,

options: *Options,
package_name_stdout: LazyPath,

pub fn create(owner: *std.Build, options: *Options, package_name_stdout: LazyPath) void {
    const builtin_options_update = owner.allocator.create(BuiltinOptionsUpdate) catch @panic("OOM");
    builtin_options_update.* = .{
        .step = Step.init(.{
            .id = base_id,
            .name = androidbuild.runNameContext("builtin_options_update"),
            .owner = owner,
            .makeFn = make,
        }),
        .options = options,
        .package_name_stdout = package_name_stdout,
    };
    // Run step relies on this finishing
    options.step.dependOn(&builtin_options_update.step);
    // Depend on package name stdout before running this step
    package_name_stdout.addStepDependencies(&builtin_options_update.step);
}

fn make(step: *Step, _: Build.Step.MakeOptions) !void {
    const b = step.owner;
    const builtin_options_update: *BuiltinOptionsUpdate = @fieldParentPtr("step", step);
    const options = builtin_options_update.options;

    const package_name_path = builtin_options_update.package_name_stdout.getPath3(b, step);

    // NOTE(jae): 2025-07-23
    // As of Zig 0.15.0-dev.1092+d772c0627, package_name_path.openFile("") is not possible as it assumes you're appending *something*
    const file = try package_name_path.root_dir.handle.openFile(package_name_path.sub_path, .{});

    // Read package name from stdout and strip line feed / carriage return
    // ie. "com.zig.sdl2\n\r"
    const package_name_filedata = try file.readToEndAlloc(b.allocator, 8192);
    const package_name_stripped = std.mem.trimRight(u8, package_name_filedata, " \r\n");
    const package_name: [:0]const u8 = try b.allocator.dupeZ(u8, package_name_stripped);

    options.addOption([:0]const u8, "package_name", package_name);
}

const BuiltinOptionsUpdate = @This();
