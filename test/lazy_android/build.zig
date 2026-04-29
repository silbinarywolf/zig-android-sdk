const Build = @import("std").Build;
const log = @import("std").log.scoped(.lazy_android);

pub fn build(b: *Build) void {
    const root_target = b.standardTargetOptions(.{});
    _ = b.standardOptimizeOption(.{});

    // Test calling lazyImport and then calling "resolveTargets"
    //
    // PR: https://github.com/silbinarywolf/zig-android-sdk/pull/83
    {
        const all_android_targets = b.option(bool, "android", "Custom usage of android flag") orelse false;
        if (!all_android_targets)
            @panic("expected android=true for the flag");
        const android_targets: []Build.ResolvedTarget = blk: {
            if (all_android_targets or root_target.result.abi.isAndroid()) {
                if (b.lazyImport(@This(), "lazy_android")) |lazy_android| {
                    break :blk lazy_android.resolveTargets(b, .{
                        .default_target = root_target,
                        .all_targets = true,
                    });
                }
            }
            break :blk &[0]Build.ResolvedTarget{};
        };
        if (android_targets.len != 4) @panic("expected 'resolveTargets' it to return 4 Android targets");

        log.info("testLazyImportAndResolveTargets: check that resolving android targets worked. Got: {}", .{android_targets.len});
    }
}
