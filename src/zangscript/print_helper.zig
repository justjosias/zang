const std = @import("std");

pub const PrintHelper = struct {
    out: *std.fs.File.OutStream,
    indentation: usize,
    indent_next: bool,

    pub fn init(out: *std.fs.File.OutStream) PrintHelper {
        return .{
            .out = out,
            .indentation = 0,
            .indent_next = false,
        };
    }

    pub fn deinit(self: *PrintHelper) void {
        std.debug.assert(self.indentation == 0);
    }

    pub fn print(self: *PrintHelper, outer_self: var, comptime fmt: []const u8, args: var) !void {
        if (self.indent_next) {
            self.indent_next = false;
            if (fmt.len > 0 and fmt[0] == '}') {
                self.indentation -= 1;
            }
            var i: usize = 0;
            while (i < self.indentation) : (i += 1) {
                try self.out.print("    ", .{});
            }
        }
        comptime var arg_index: usize = 0;
        comptime var i: usize = 0;
        inline while (i < fmt.len) {
            if (fmt[i] == '}' and i + 1 < fmt.len and fmt[i + 1] == '}') {
                try self.out.writeByte('}');
                i += 2;
                continue;
            }
            if (fmt[i] == '{') {
                i += 1;

                if (i < fmt.len and fmt[i] == '{') {
                    try self.out.writeByte('{');
                    i += 1;
                    continue;
                }

                // find the closing brace
                const start = i;
                inline while (i < fmt.len) : (i += 1) {
                    if (fmt[i] == '}') break;
                }
                if (i == fmt.len) {
                    @compileError("`{` must be followed by `}`");
                }
                const arg_format = fmt[start..i];
                i += 1;

                const arg = args[arg_index];
                arg_index += 1;

                if (comptime std.mem.eql(u8, arg_format, "auto")) {
                    try self.out.print("{}", .{arg});
                } else if (comptime std.mem.eql(u8, arg_format, "bool")) {
                    try self.out.print("{}", .{@as(bool, arg)});
                } else if (comptime std.mem.eql(u8, arg_format, "f32")) {
                    // FIXME - make sure there's a decimal point in there, for zig generation
                    // (so that something like `1 / 10` doesn't get evaluated as integer division)
                    // then i could get rid of the `@as(f32, literal)` hack for division
                    try self.out.print("{d}", .{@as(f32, arg)});
                } else if (comptime std.mem.eql(u8, arg_format, "usize")) {
                    try self.out.print("{}", .{@as(usize, arg)});
                } else if (comptime std.mem.eql(u8, arg_format, "str")) {
                    try self.out.writeAll(arg);
                } else {
                    try outer_self.printArgValue(arg_format, arg);
                }
            } else {
                try self.out.writeByte(fmt[i]);
                i += 1;
            }
        }
        if (fmt.len >= 1 and fmt[fmt.len - 1] == '\n') {
            self.indent_next = true;
            if (fmt.len >= 2 and fmt[fmt.len - 2] == '{') {
                self.indentation += 1;
            }
        }
    }
};
