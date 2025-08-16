const builtin = @import("builtin");
const std = @import("std");

const paths = @import("paths.zig");

const logger = std.log.scoped(.dll_proxy);

const dll_names: []const [:0]const u8 = &.{ "version", "winhttp" };

const DllName = blk: {
    var fields: []const std.builtin.Type.EnumField = &.{};

    for (dll_names, 0..) |dll_name, i| {
        fields = fields ++ .{std.builtin.Type.EnumField{
            .name = dll_name,
            .value = i,
        }};
    }

    break :blk @Type(.{ .@"enum" = .{
        .fields = fields,
        .decls = &.{},
        .tag_type = u8,
        .is_exhaustive = true,
    } });
};

fn proxyFunctions(comptime dll_name: []const u8) []const []const u8 {
    var buf: []const []const u8 = &.{};

    var funcs = std.mem.splitScalar(u8, @embedFile("symbols/" ++ dll_name ++ ".txt"), '\n');
    while (funcs.next()) |name| {
        if (name.len == 0) {
            continue;
        }
        if (std.mem.indexOfScalar(u8, name, ' ') != null) {
            @compileError("proxy function name \"" ++ name ++ "\" contains whitespace");
        }
        buf = buf ++ .{name};
    }

    return buf;
}

const DllIncludes = blk: {
    var fields: []const std.builtin.Type.StructField = &.{};

    for (std.meta.fieldNames(ProxyFuncAddrs)) |func_name| {
        fields = fields ++ .{std.builtin.Type.StructField{
            .name = func_name,
            .type = bool,
            .default_value_ptr = &false,
            .is_comptime = false,
            .alignment = 0,
        }};
    }

    break :blk @Type(.{ .@"struct" = .{
        .layout = .@"packed",
        .fields = fields,
        .decls = &.{},
        .is_tuple = false,
    } });
};

const EachDllIncludes = blk: {
    var fields: []const std.builtin.Type.StructField = &.{};

    for (dll_names) |dll_name| {
        fields = fields ++ .{std.builtin.Type.StructField{
            .name = dll_name,
            .type = DllIncludes,
            .default_value_ptr = &DllIncludes{},
            .is_comptime = false,
            .alignment = @alignOf(DllIncludes),
        }};
    }

    break :blk @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = fields,
        .decls = &.{},
        .is_tuple = false,
    } });
};

const each_dll_includes = blk: {
    @setEvalBranchQuota(8000);

    var includes: EachDllIncludes = .{};

    for (dll_names) |dll_name| {
        for (proxyFunctions(dll_name)) |name| {
            @field(@field(includes, dll_name), name) = true;
        }
    }

    break :blk includes;
};

const ProxyFuncAddrs = blk: {
    @setEvalBranchQuota(8000);

    var fields: []const std.builtin.Type.StructField = &.{};

    for (dll_names) |dll_name| {
        for (proxyFunctions(dll_name)) |name| {
            const FuncAddr = ?*fn () callconv(.c) void;
            fields = fields ++ .{std.builtin.Type.StructField{
                .name = @ptrCast(name ++ .{0}),
                .type = FuncAddr,
                .default_value_ptr = @ptrCast(&@as(FuncAddr, null)),
                .is_comptime = false,
                .alignment = @alignOf(FuncAddr),
            }};
        }
    }

    break :blk @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = fields,
        .decls = &.{},
        .is_tuple = false,
    } });
};

var proxy_func_addrs: ProxyFuncAddrs = .{};

fn panicUnlinkedFunction(name: []const u8) noreturn {
    @branchHint(.cold);
    std.debug.panic("Attempted to call unlinked function {s}", .{name});
}

comptime {
    for (std.meta.fieldNames(ProxyFuncAddrs)) |name| {
        @export(&struct {
            fn f() callconv(.c) void {
                if (@field(proxy_func_addrs, name)) |func| {
                    return func();
                } else {
                    panicUnlinkedFunction(name);
                }
            }
        }.f, .{ .name = name });
    }
}

fn getDllIncludes(dll_name: DllName) *const DllIncludes {
    inline for (dll_names) |other_dll_name| {
        if (@field(DllName, other_dll_name) == dll_name) {
            return &@field(each_dll_includes, other_dll_name);
        }
    }
    unreachable;
}

fn logUnlinkableFunction(name: []const u8, path: []const u16) void {
    @branchHint(.cold);
    logger.warn("Failed to locate function {s} in {f}", .{ name, std.unicode.fmtUtf16Le(path) });
}

fn loadFunctions(dll: std.os.windows.HMODULE, path: []const u16, dll_name: DllName) void {
    const includes = getDllIncludes(dll_name);
    inline for (comptime std.meta.fieldNames(ProxyFuncAddrs)) |field| {
        if (@field(includes, field)) {
            if (std.os.windows.kernel32.GetProcAddress(dll, field)) |ptr| {
                @field(proxy_func_addrs, field) = @ptrCast(ptr);
            } else {
                logUnlinkableFunction(field, path);
            }
        }
    }
}

fn eqlIgnoreCase(a: []const u16, b: []const u8) bool {
    if (a.len != b.len) {
        return false;
    }
    for (a, b) |a_c16, b_c| {
        const a_c = std.math.cast(u8, a_c16) orelse return false;
        if (std.ascii.toLower(a_c) != b_c) {
            return false;
        }
    }
    return true;
}

fn empty(comptime T: type) *[0:0]T {
    return @constCast(&[_:0]T{});
}

fn findDllMatch(module_name: []const u16) ?DllName {
    if (module_name.len > 4 and eqlIgnoreCase(module_name[module_name.len - 4 ..], ".dll")) {
        const module_name_stripped = module_name[0 .. module_name.len - 4];
        inline for (dll_names) |dll_name| {
            if (eqlIgnoreCase(module_name_stripped, dll_name)) {
                return @field(DllName, dll_name);
            }
        }
    }
    return null;
}

pub fn loadProxy(module: std.os.windows.HMODULE) !void {
    var module_path_buf = paths.ModulePathBuf{};
    const module_path = (try module_path_buf.get(module)).?;

    const module_name = paths.getFileName(u16, module_path);

    const dll_name = findDllMatch(module_name) orelse {
        logger.debug("{f} is not supported for proxying", .{std.unicode.fmtUtf16Le(module_name)});
        return error.UnsupportedName;
    };
    logger.debug("Detected injection as supported proxy {f}. Loading actual.", .{std.unicode.fmtUtf16Le(module_name)});

    // sys_len includes null-terminator
    const sys_len = std.os.windows.kernel32.GetSystemDirectoryW(empty(u16), 0);
    var sys_full_path_buf: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
    if (sys_len + module_name.len > sys_full_path_buf.len) {
        return error.OutOfMemory;
    }
    const n = std.os.windows.kernel32.GetSystemDirectoryW(&sys_full_path_buf, sys_len);
    std.debug.assert(n == sys_len - 1);
    sys_full_path_buf[n] = std.fs.path.sep;
    @memcpy(sys_full_path_buf[n + 1 ..][0..module_name.len], module_name);
    sys_full_path_buf[sys_len + module_name.len] = 0;
    const sys_full_path = sys_full_path_buf[0 .. sys_len + module_name.len :0];

    logger.debug("Looking for actual DLL at {f}", .{std.unicode.fmtUtf16Le(sys_full_path)});

    const handle = try std.os.windows.LoadLibraryW(sys_full_path);

    loadFunctions(handle, sys_full_path, dll_name);
}

test {
    if (builtin.os.tag == .windows) {
        std.testing.refAllDecls(@This());
    }
}

test "dump" {
    // This test exists for manual verification that the symbol filtering is working correctly.
    // There is no need to run and dump every time.
    if (true) {
        return;
    }
    for (std.meta.tags(DllName)) |name| {
        const includes = getDllIncludes(name);
        std.debug.print("{s}:\n", .{@tagName(name)});
        inline for (comptime std.meta.fieldNames(ProxyFuncAddrs)) |field| {
            if (@field(includes, field)) {
                std.debug.print("  {s}\n", .{field});
            }
        }
    }
}

test "findDllMatch" {
    const utf16Lit = std.unicode.utf8ToUtf16LeStringLiteral;

    try std.testing.expectEqual(.version, findDllMatch(utf16Lit("VERSION.DLL")));
    try std.testing.expectEqual(.version, findDllMatch(utf16Lit("version.dll")));
    try std.testing.expectEqual(.version, findDllMatch(utf16Lit("versIon.dll")));

    try std.testing.expectEqual(.winhttp, findDllMatch(utf16Lit("WINHTTP.DLL")));
    try std.testing.expectEqual(.winhttp, findDllMatch(utf16Lit("winhttp.dll")));
    try std.testing.expectEqual(.winhttp, findDllMatch(utf16Lit("WinhttP.DLL")));
}
