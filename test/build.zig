const Build = @import("std").Build;
const builtin = @import("builtin");
const eql = @import("std").mem.eql;

/// Make sure this is a stable version of Zig
const is_latest_stable_zig = builtin.zig_version.pre == null and
    builtin.zig_version.major == 0 and builtin.zig_version.minor >= 16;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const all_step = b.step("all", "Run all tests");
    b.default_step = all_step;

    for (b.available_deps) |available_dep| {
        const test_name, _ = available_dep;
        const test_case_dep_step: *Build.Step = blk: {
            if (is_latest_stable_zig) {
                const dep = b.dependency(test_name, .{
                    .target = target,
                    .optimize = optimize,
                    .android = true,
                });
                break :blk dep.builder.default_step;
            } else {
                // Skip translate_c_dep as it requires Zig 0.16.0 stable as of 2026-04-29
                if (eql(u8, test_name, "translate_c_dep")) {
                    continue;
                }

                // NOTE(jae): 2026-04-29
                // Due to b.dependency() trying to always load Zig dependencies regardless
                // of version requirements, we make other Zig versions invoke build manually
                // so that ignoring dependency logic is respected.
                const cmd = b.addSystemCommand(&.{ "zig", "build", "-Dandroid=true" });
                cmd.setCwd(b.path(test_name));
                cmd.expectExitCode(0);
                break :blk &cmd.step;
            }
        };
        const test_step = b.step(test_name, b.fmt("Run the '{s}' test", .{test_name}));
        test_step.dependOn(test_case_dep_step);
        all_step.dependOn(test_step);
    }
}
