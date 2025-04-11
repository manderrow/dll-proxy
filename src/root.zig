const builtin = @import("builtin");
const std = @import("std");

const paths = @import("paths.zig");

pub const logger = std.log.scoped(.lib_proxy);

const dll_name = "winhttp";

const iter_proxy_funcs = std.mem.splitScalar(u8, @embedFile("symbols/" ++ dll_name ++ ".txt"), '\n');

const ProxyFuncAddrs = blk: {
    @setEvalBranchQuota(8000);

    var fields: []const std.builtin.Type.StructField = &.{};

    var funcs = iter_proxy_funcs;
    while (funcs.next()) |name| {
        if (std.mem.indexOfScalar(u8, name, ' ') != null) {
            @compileError("proxy function name \"" ++ name ++ "\" contains whitespace");
        }
        fields = fields ++ .{std.builtin.Type.StructField{
            .name = @ptrCast(name ++ .{0}),
            .type = std.os.windows.FARPROC,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(std.os.windows.FARPROC),
        }};
    }

    break :blk @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = fields,
        .decls = &.{},
        .is_tuple = false,
    } });
};

var proxy_func_addrs: ProxyFuncAddrs = undefined;

comptime {
    @setEvalBranchQuota(8000);
    var funcs = iter_proxy_funcs;
    while (funcs.next()) |name| {
        @export(&struct {
            fn f() callconv(.c) void {
                return @as(*fn () callconv(.c) void, @ptrCast(@field(proxy_func_addrs, name)))();
            }
        }.f, .{ .name = name });
    }
}

fn loadFunctions(dll: std.os.windows.HMODULE) void {
    inline for (comptime std.meta.fieldNames(ProxyFuncAddrs)) |field| {
        @field(proxy_func_addrs, field) = std.os.windows.kernel32.GetProcAddress(dll, field).?;
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

pub fn loadProxy(module: std.os.windows.HMODULE) !void {
    var module_path_buf = paths.ModulePathBuf{};
    const module_path = (try module_path_buf.get(module)).?;

    const module_name = paths.getFileName(u16, module_path);

    const proxy_name = dll_name ++ ".dll";
    if (!eqlIgnoreCase(module_name, proxy_name)) {
        logger.debug("{s} is not supported for proxying", .{std.unicode.fmtUtf16Le(module_name)});
        return error.UnsupportedName;
    }
    logger.debug("Detected injection as supported proxy. Loading actual.", .{});

    // sys_len includes null-terminator
    const sys_len = std.os.windows.kernel32.GetSystemDirectoryW(empty(u16), 0);
    var sys_full_path_buf: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
    if (sys_len + module_name.len > sys_full_path_buf.len) {
        return error.OutOfMemory;
    }
    const n = std.os.windows.kernel32.GetSystemDirectoryW(&sys_full_path_buf, sys_len);
    std.debug.assert(n == sys_len - 1);
    sys_full_path_buf[n] = std.fs.path.sep;
    @memcpy(sys_full_path_buf[n + 1 ..], module_name);
    sys_full_path_buf[sys_len + module_name.len] = 0;
    const sys_full_path = sys_full_path_buf[0 .. sys_len + module_name.len :0];

    logger.debug("Looking for actual DLL at {s}", .{std.unicode.fmtUtf16Le(sys_full_path)});

    const handle = try std.os.windows.LoadLibraryW(sys_full_path);

    loadFunctions(handle);
}
