const builtin = @import("builtin");
const std = @import("std");

pub const ModulePathBuf = struct {
    buf: [std.os.windows.PATH_MAX_WIDE]u16 = undefined,

    pub fn get(self: *@This(), module: ?std.os.windows.HMODULE) !?[:0]const u16 {
        self.* = undefined;
        // see https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getmodulefilenamew
        const rc = std.os.windows.kernel32.GetModuleFileNameW(module, &self.buf, self.buf.len);
        if (rc == 0) {
            return std.os.windows.unexpectedError(std.os.windows.GetLastError());
        }
        if (std.os.windows.GetLastError() == .INSUFFICIENT_BUFFER) {
            // should not be able to exceed PATH_MAX_WIDE
            unreachable;
        }
        return self.buf[0..rc :0];
    }
};

fn splitPath(comptime Char: type, path: []const Char) usize {
    if (path.len == 0) {
        @panic("Empty path provided to splitPath");
    }
    var i = path.len;
    while (true) {
        i -= 1;
        const c = path[i];
        if (c == '/' or c == '\\') {
            return .{ .parent = i + 1 };
        }
        if (i == 0) {
            return .{ .parent = 0 };
        }
    }
}

pub fn getFileName(comptime Char: type, path: []const Char) []const Char {
    return path[splitPath(Char, path)..];
}

test "get_file_name" {
    try std.testing.expectEqualStrings("baz", getFileName(u8, "/foo/bar/baz"));
    try std.testing.expectEqualStrings("baz.txt", getFileName(u8, "/foo/bar/baz.txt"));
    try std.testing.expectEqualStrings("baz.txt", getFileName(u8, "baz.txt"));
}
