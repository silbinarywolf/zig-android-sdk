//! BuiltinOptionsUpdate will update the *Options

const androidbuild = @import("androidbuild.zig");
const builtin = @import("builtin");
const Build = @import("std").Build;
const Step = Build.Step;
const Options = Build.Step.Options;
const LazyPath = Build.LazyPath;
const fs = @import("std").fs;
const mem = @import("std").mem;
const assert = @import("std").debug.assert;

pub const base_id: Step.Id = .custom;

step: Step,

options: *Options,
package_name_stdout: LazyPath,

pub fn create(owner: *Build, package_name_stdout: LazyPath) *BuiltinOptionsUpdate {
    const options = Build.addOptions(owner);

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
    return builtin_options_update;
}

pub fn createModule(self: *BuiltinOptionsUpdate) *Build.Module {
    return self.options.createModule();
}

fn make(step: *Step, _: Build.Step.MakeOptions) !void {
    const b = step.owner;
    const builtin_options_update: *BuiltinOptionsUpdate = @fieldParentPtr("step", step);
    const options = builtin_options_update.options;

    // If using --watch and the user updated AndroidManifest.xml, this step can be re-triggered.
    //
    // To avoid appending multiple "package_name = " lines to the output module, we need to clear it if
    // the options step has any contents
    if (options.contents.items.len > 0) {
        options.contents.clearRetainingCapacity();
    }

    const package_name_path = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
        builtin_options_update.package_name_stdout.getPath3(b, step)
    else
        try builtin_options_update.package_name_stdout.getPath4(b, step);

    // Read package name from stdout and strip line feed / carriage return
    // ie. "com.zig.sdl2\n\r"
    const package_name_backing_buf = try b.allocator.alloc(u8, 8192);
    defer b.allocator.free(package_name_backing_buf);

    const package_name_filedata = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15)
        try package_name_path.root_dir.handle.readFile(package_name_path.sub_path, package_name_backing_buf)
    else
        try package_name_path.root_dir.handle.readFile(b.graph.io, package_name_path.sub_path, package_name_backing_buf);
    const package_name_stripped = if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 14)
        mem.trimRight(u8, package_name_filedata, " \r\n")
    else
        mem.trimEnd(u8, package_name_filedata, " \r\n");
    const package_name: [:0]const u8 = try b.allocator.dupeZ(u8, package_name_stripped);

    options.addOption([:0]const u8, "package_name", package_name);
}

const BuiltinOptionsUpdate = @This();
