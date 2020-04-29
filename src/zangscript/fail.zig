const std = @import("std");
const BuiltinEnumValue = @import("builtins.zig").BuiltinEnumValue;
const Source = @import("tokenize.zig").Source;
const SourceRange = @import("tokenize.zig").SourceRange;

fn printSourceRange(out: *std.fs.File.OutStream, contents: []const u8, source_range: SourceRange) !void {
    try out.writeAll(contents[source_range.loc0.index..source_range.loc1.index]);
}

fn printErrorMessage(out: *std.fs.File.OutStream, maybe_source_range: ?SourceRange, contents: []const u8, comptime fmt: []const u8, args: var) !void {
    comptime var arg_index: usize = 0;
    inline for (fmt) |ch| {
        if (ch == '%') {
            // source range
            try printSourceRange(out, contents, args[arg_index]);
            arg_index += 1;
        } else if (ch == '#') {
            // string
            try out.writeAll(args[arg_index]);
            arg_index += 1;
        } else if (ch == '<') {
            // the maybe_source_range that was passed in
            if (maybe_source_range) |source_range| {
                try printSourceRange(out, contents, source_range);
            } else {
                try out.writeByte('?');
            }
        } else if (ch == '|') {
            // list of enum values
            const values: []const BuiltinEnumValue = args[arg_index];
            for (values) |value, i| {
                if (i > 0) try out.writeAll(", ");
                try out.writeByte('\'');
                try out.writeAll(value.label);
                try out.writeByte('\'');
                switch (value.payload_type) {
                    .none => {},
                    .f32 => try out.writeAll("(number)"),
                }
            }
            arg_index += 1;
        } else {
            try out.writeByte(ch);
        }
    }
}

const KNRM = "\x1B[0m";
const KBOLD = "\x1B[1m";
const KRED = "\x1B[31m";
const KYEL = "\x1B[33m";
const KWHITE = "\x1B[37m";

fn printError(source: Source, maybe_source_range: ?SourceRange, comptime fmt: []const u8, args: var) !void {
    const held = std.debug.getStderrMutex().acquire();
    defer held.release();
    const out = std.debug.getStderrStream();

    const source_range = maybe_source_range orelse {
        // we don't know where in the source file the error occurred
        try out.print(KYEL ++ KBOLD ++ "{}: " ++ KWHITE, .{source.filename});
        try printErrorMessage(out, null, source.contents, fmt, args);
        try out.print(KNRM ++ "\n\n", .{});
        return;
    };

    // we want to echo the problematic line from the source file.
    // look backward to find the start of the line
    var i: usize = source_range.loc0.index;
    while (i > 0) : (i -= 1) {
        if (source.contents[i - 1] == '\n') {
            break;
        }
    }
    const start = i;
    // look forward to find the end of the line
    i = source_range.loc0.index;
    while (i < source.contents.len) : (i += 1) {
        if (source.contents[i] == '\n' or source.contents[i] == '\r') {
            break;
        }
    }
    const end = i;

    const line_num = source_range.loc0.line + 1;
    const column_num = source_range.loc0.index - start + 1;

    // print source filename, line number, and column number
    try out.print(KYEL ++ KBOLD ++ "{}:{}:{}: " ++ KWHITE, .{ source.filename, line_num, column_num });

    // print the error message
    try printErrorMessage(out, maybe_source_range, source.contents, fmt, args);
    try out.print(KNRM ++ "\n\n", .{});

    if (source_range.loc0.index == source_range.loc1.index) {
        // if there's no span, it's probably an "expected X, found end of file" error.
        // there's nothing to echo (but we still want to show the line number)
        return;
    }

    // echo the source line
    try out.print("{}\n", .{source.contents[start..end]});

    // show arrows pointing at the problematic span
    i = start;
    while (i < source_range.loc0.index) : (i += 1) {
        try out.print(" ", .{});
    }
    try out.writeAll(KRED ++ KBOLD);
    while (i < end and i < source_range.loc1.index) : (i += 1) {
        try out.print("^", .{});
    }
    try out.writeAll(KNRM);
    try out.print("\n", .{});
}

pub fn fail(source: Source, maybe_source_range: ?SourceRange, comptime fmt: []const u8, args: var) error{Failed} {
    printError(source, maybe_source_range, fmt, args) catch {};
    return error.Failed;
}
