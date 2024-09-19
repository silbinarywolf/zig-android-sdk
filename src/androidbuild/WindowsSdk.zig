// NOTE(jae): 2024-09-15
// Copy paste of lib/std/zig/WindowsSdk.zig but cutdown to only use Registry functions

const WindowsSdk = @This();
const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;
const RRF = windows.advapi32.RRF;

const OpenOptions = struct {
    /// Sets the KEY_WOW64_32KEY access flag.
    /// https://learn.microsoft.com/en-us/windows/win32/winprog64/accessing-an-alternate-registry-view
    wow64_32: bool = false,
};

pub const RegistryWtf8 = struct {
    key: windows.HKEY,

    /// Assert that `key` is valid WTF-8 string
    pub fn openKey(hkey: windows.HKEY, key: []const u8, options: OpenOptions) error{KeyNotFound}!RegistryWtf8 {
        const key_wtf16le: [:0]const u16 = key_wtf16le: {
            var key_wtf16le_buf: [RegistryWtf16Le.key_name_max_len]u16 = undefined;
            const key_wtf16le_len: usize = std.unicode.wtf8ToWtf16Le(key_wtf16le_buf[0..], key) catch |err| switch (err) {
                error.InvalidWtf8 => unreachable,
            };
            key_wtf16le_buf[key_wtf16le_len] = 0;
            break :key_wtf16le key_wtf16le_buf[0..key_wtf16le_len :0];
        };

        const registry_wtf16le = try RegistryWtf16Le.openKey(hkey, key_wtf16le, options);
        return .{ .key = registry_wtf16le.key };
    }

    /// Closes key, after that usage is invalid
    pub fn closeKey(reg: RegistryWtf8) void {
        const return_code_int: windows.HRESULT = windows.advapi32.RegCloseKey(reg.key);
        const return_code: windows.Win32Error = @enumFromInt(return_code_int);
        switch (return_code) {
            .SUCCESS => {},
            else => {},
        }
    }

    /// Get string from registry.
    /// Caller owns result.
    pub fn getString(reg: RegistryWtf8, allocator: std.mem.Allocator, subkey: []const u8, value_name: []const u8) error{ OutOfMemory, ValueNameNotFound, NotAString, StringNotFound }![]u8 {
        const subkey_wtf16le: [:0]const u16 = subkey_wtf16le: {
            var subkey_wtf16le_buf: [RegistryWtf16Le.key_name_max_len]u16 = undefined;
            const subkey_wtf16le_len: usize = std.unicode.wtf8ToWtf16Le(subkey_wtf16le_buf[0..], subkey) catch unreachable;
            subkey_wtf16le_buf[subkey_wtf16le_len] = 0;
            break :subkey_wtf16le subkey_wtf16le_buf[0..subkey_wtf16le_len :0];
        };

        const value_name_wtf16le: [:0]const u16 = value_name_wtf16le: {
            var value_name_wtf16le_buf: [RegistryWtf16Le.value_name_max_len]u16 = undefined;
            const value_name_wtf16le_len: usize = std.unicode.wtf8ToWtf16Le(value_name_wtf16le_buf[0..], value_name) catch unreachable;
            value_name_wtf16le_buf[value_name_wtf16le_len] = 0;
            break :value_name_wtf16le value_name_wtf16le_buf[0..value_name_wtf16le_len :0];
        };

        const registry_wtf16le: RegistryWtf16Le = .{ .key = reg.key };
        const value_wtf16le = try registry_wtf16le.getString(allocator, subkey_wtf16le, value_name_wtf16le);
        defer allocator.free(value_wtf16le);

        const value_wtf8: []u8 = try std.unicode.wtf16LeToWtf8Alloc(allocator, value_wtf16le);
        errdefer allocator.free(value_wtf8);

        return value_wtf8;
    }

    /// Get DWORD (u32) from registry.
    pub fn getDword(reg: RegistryWtf8, subkey: []const u8, value_name: []const u8) error{ ValueNameNotFound, NotADword, DwordTooLong, DwordNotFound }!u32 {
        const subkey_wtf16le: [:0]const u16 = subkey_wtf16le: {
            var subkey_wtf16le_buf: [RegistryWtf16Le.key_name_max_len]u16 = undefined;
            const subkey_wtf16le_len: usize = std.unicode.wtf8ToWtf16Le(subkey_wtf16le_buf[0..], subkey) catch unreachable;
            subkey_wtf16le_buf[subkey_wtf16le_len] = 0;
            break :subkey_wtf16le subkey_wtf16le_buf[0..subkey_wtf16le_len :0];
        };

        const value_name_wtf16le: [:0]const u16 = value_name_wtf16le: {
            var value_name_wtf16le_buf: [RegistryWtf16Le.value_name_max_len]u16 = undefined;
            const value_name_wtf16le_len: usize = std.unicode.wtf8ToWtf16Le(value_name_wtf16le_buf[0..], value_name) catch unreachable;
            value_name_wtf16le_buf[value_name_wtf16le_len] = 0;
            break :value_name_wtf16le value_name_wtf16le_buf[0..value_name_wtf16le_len :0];
        };

        const registry_wtf16le: RegistryWtf16Le = .{ .key = reg.key };
        return registry_wtf16le.getDword(subkey_wtf16le, value_name_wtf16le);
    }

    /// Under private space with flags:
    /// KEY_QUERY_VALUE and KEY_ENUMERATE_SUB_KEYS.
    /// After finishing work, call `closeKey`.
    pub fn loadFromPath(absolute_path: []const u8) error{KeyNotFound}!RegistryWtf8 {
        const absolute_path_wtf16le: [:0]const u16 = absolute_path_wtf16le: {
            var absolute_path_wtf16le_buf: [RegistryWtf16Le.value_name_max_len]u16 = undefined;
            const absolute_path_wtf16le_len: usize = std.unicode.wtf8ToWtf16Le(absolute_path_wtf16le_buf[0..], absolute_path) catch unreachable;
            absolute_path_wtf16le_buf[absolute_path_wtf16le_len] = 0;
            break :absolute_path_wtf16le absolute_path_wtf16le_buf[0..absolute_path_wtf16le_len :0];
        };

        const registry_wtf16le = try RegistryWtf16Le.loadFromPath(absolute_path_wtf16le);
        return .{ .key = registry_wtf16le.key };
    }
};

const RegistryWtf16Le = struct {
    key: windows.HKEY,

    /// Includes root key (f.e. HKEY_LOCAL_MACHINE).
    /// https://learn.microsoft.com/en-us/windows/win32/sysinfo/registry-element-size-limits
    pub const key_name_max_len = 255;
    /// In Unicode characters.
    /// https://learn.microsoft.com/en-us/windows/win32/sysinfo/registry-element-size-limits
    pub const value_name_max_len = 16_383;

    /// Under HKEY_LOCAL_MACHINE with flags:
    /// KEY_QUERY_VALUE, KEY_ENUMERATE_SUB_KEYS, optionally KEY_WOW64_32KEY.
    /// After finishing work, call `closeKey`.
    fn openKey(hkey: windows.HKEY, key_wtf16le: [:0]const u16, options: OpenOptions) error{KeyNotFound}!RegistryWtf16Le {
        var key: windows.HKEY = undefined;
        var access: windows.REGSAM = windows.KEY_QUERY_VALUE | windows.KEY_ENUMERATE_SUB_KEYS;
        if (options.wow64_32) access |= windows.KEY_WOW64_32KEY;
        const return_code_int: windows.HRESULT = windows.advapi32.RegOpenKeyExW(
            hkey,
            key_wtf16le,
            0,
            access,
            &key,
        );
        const return_code: windows.Win32Error = @enumFromInt(return_code_int);
        switch (return_code) {
            .SUCCESS => {},
            .FILE_NOT_FOUND => return error.KeyNotFound,

            else => return error.KeyNotFound,
        }
        return .{ .key = key };
    }

    /// Closes key, after that usage is invalid
    fn closeKey(reg: RegistryWtf16Le) void {
        const return_code_int: windows.HRESULT = windows.advapi32.RegCloseKey(reg.key);
        const return_code: windows.Win32Error = @enumFromInt(return_code_int);
        switch (return_code) {
            .SUCCESS => {},
            else => {},
        }
    }

    /// Get string ([:0]const u16) from registry.
    fn getString(reg: RegistryWtf16Le, allocator: std.mem.Allocator, subkey_wtf16le: [:0]const u16, value_name_wtf16le: [:0]const u16) error{ OutOfMemory, ValueNameNotFound, NotAString, StringNotFound }![]const u16 {
        var actual_type: windows.ULONG = undefined;

        // Calculating length to allocate
        var value_wtf16le_buf_size: u32 = 0; // in bytes, including any terminating NUL character or characters.
        var return_code_int: windows.HRESULT = windows.advapi32.RegGetValueW(
            reg.key,
            subkey_wtf16le,
            value_name_wtf16le,
            RRF.RT_REG_SZ,
            &actual_type,
            null,
            &value_wtf16le_buf_size,
        );

        // Check returned code and type
        var return_code: windows.Win32Error = @enumFromInt(return_code_int);
        switch (return_code) {
            .SUCCESS => std.debug.assert(value_wtf16le_buf_size != 0),
            .MORE_DATA => unreachable, // We are only reading length
            .FILE_NOT_FOUND => return error.ValueNameNotFound,
            .INVALID_PARAMETER => unreachable, // We didn't combine RRF.SUBKEY_WOW6464KEY and RRF.SUBKEY_WOW6432KEY
            else => return error.StringNotFound,
        }
        switch (actual_type) {
            windows.REG.SZ => {},
            else => return error.NotAString,
        }

        const value_wtf16le_buf: []u16 = try allocator.alloc(u16, std.math.divCeil(u32, value_wtf16le_buf_size, 2) catch unreachable);
        errdefer allocator.free(value_wtf16le_buf);

        return_code_int = windows.advapi32.RegGetValueW(
            reg.key,
            subkey_wtf16le,
            value_name_wtf16le,
            RRF.RT_REG_SZ,
            &actual_type,
            value_wtf16le_buf.ptr,
            &value_wtf16le_buf_size,
        );

        // Check returned code and (just in case) type again.
        return_code = @enumFromInt(return_code_int);
        switch (return_code) {
            .SUCCESS => {},
            .MORE_DATA => unreachable, // Calculated first time length should be enough, even overestimated
            .FILE_NOT_FOUND => return error.ValueNameNotFound,
            .INVALID_PARAMETER => unreachable, // We didn't combine RRF.SUBKEY_WOW6464KEY and RRF.SUBKEY_WOW6432KEY
            else => return error.StringNotFound,
        }
        switch (actual_type) {
            windows.REG.SZ => {},
            else => return error.NotAString,
        }

        const value_wtf16le: []const u16 = value_wtf16le: {
            // note(bratishkaerik): somehow returned value in `buf_len` is overestimated by Windows and contains extra space
            // we will just search for zero termination and forget length
            // Windows sure is strange
            const value_wtf16le_overestimated: [*:0]const u16 = @ptrCast(value_wtf16le_buf.ptr);
            break :value_wtf16le std.mem.span(value_wtf16le_overestimated);
        };

        _ = allocator.resize(value_wtf16le_buf, value_wtf16le.len);
        return value_wtf16le;
    }

    /// Get DWORD (u32) from registry.
    fn getDword(reg: RegistryWtf16Le, subkey_wtf16le: [:0]const u16, value_name_wtf16le: [:0]const u16) error{ ValueNameNotFound, NotADword, DwordTooLong, DwordNotFound }!u32 {
        var actual_type: windows.ULONG = undefined;
        var reg_size: u32 = @sizeOf(u32);
        var reg_value: u32 = 0;

        const return_code_int: windows.HRESULT = windows.advapi32.RegGetValueW(
            reg.key,
            subkey_wtf16le,
            value_name_wtf16le,
            RRF.RT_REG_DWORD,
            &actual_type,
            &reg_value,
            &reg_size,
        );
        const return_code: windows.Win32Error = @enumFromInt(return_code_int);
        switch (return_code) {
            .SUCCESS => {},
            .MORE_DATA => return error.DwordTooLong,
            .FILE_NOT_FOUND => return error.ValueNameNotFound,
            .INVALID_PARAMETER => unreachable, // We didn't combine RRF.SUBKEY_WOW6464KEY and RRF.SUBKEY_WOW6432KEY
            else => return error.DwordNotFound,
        }

        switch (actual_type) {
            windows.REG.DWORD => {},
            else => return error.NotADword,
        }

        return reg_value;
    }

    /// Under private space with flags:
    /// KEY_QUERY_VALUE and KEY_ENUMERATE_SUB_KEYS.
    /// After finishing work, call `closeKey`.
    fn loadFromPath(absolute_path_as_wtf16le: [:0]const u16) error{KeyNotFound}!RegistryWtf16Le {
        var key: windows.HKEY = undefined;

        const return_code_int: windows.HRESULT = std.os.windows.advapi32.RegLoadAppKeyW(
            absolute_path_as_wtf16le,
            &key,
            windows.KEY_QUERY_VALUE | windows.KEY_ENUMERATE_SUB_KEYS,
            0,
            0,
        );
        const return_code: windows.Win32Error = @enumFromInt(return_code_int);
        switch (return_code) {
            .SUCCESS => {},
            else => return error.KeyNotFound,
        }

        return .{ .key = key };
    }
};
