const std = @import("std");
const Token = @import("tokenizer.zig").Token;
const TokenType = @import("tokenizer.zig").TokenType;
const ResolvedParamType = @import("first_pass.zig").ResolvedParamType;

pub const Source = struct {
    filename: []const u8,
    contents: []const u8,
};

pub const SourceLocation = struct {
    // which line in the source file (starts at 0)
    line: usize,
    // byte offset into source file.
    // the column can be found by searching backward for a newline
    index: usize,
};

pub const SourceRange = struct {
    loc0: SourceLocation,
    loc1: SourceLocation,
};

fn printSourceRange(stderr: var, contents: []const u8, source_range: SourceRange) void {
    // TODO would be nice if it could say "keyword `param`" instead of just "`param`"
    // first i need to move the backquotes into here...
    stderr.write(contents[source_range.loc0.index..source_range.loc1.index]) catch {};
}

fn failPrint(stderr: var, contents: []const u8, comptime fmt: []const u8, args: var) void {
    comptime var j: usize = 0;
    inline for (fmt) |ch| {
        // idea: another character which just points to the "subject" token (the one the arrow points to).
        // no reason i should have to pass that token twice if i want to describe it in the error message too
        if (ch == '%') {
            // source range
            printSourceRange(stderr, contents, args[j]);
            j += 1;
        } else if (ch == '&') {
            // data type
            stderr.write("(datatype)") catch {};
            // FIXME this crashes the compiler
            //switch (args[j]) {
            //    .boolean => stderr.write("boolean") catch {},
            //    .constant => stderr.write("constant") catch {},
            //    .constant_or_buffer => stderr.write("constant_or_buffer") catch {},
            //}
            j += 1;
        } else if (ch == '#') {
            // string
            stderr.write(args[j]) catch {};
            j += 1;
        } else {
            stderr.writeByte(ch) catch {};
        }
    }
}

const KNRM = "\x1B[0m";
const KBOLD = "\x1B[1m";
const KRED = "\x1B[31m";
const KYEL = "\x1B[33m";
const KWHITE = "\x1B[37m";

pub fn fail(
    source: Source,
    maybe_source_range: ?SourceRange,
    comptime fmt: []const u8,
    args: var,
) error{Failed} {
    const source_range = maybe_source_range orelse {
        const held = std.debug.getStderrMutex().acquire();
        defer held.release();
        const stderr = std.debug.getStderrStream();
        stderr.print(KYEL ++ KBOLD ++ "{}: " ++ KWHITE, .{source.filename}) catch {};
        failPrint(stderr, source.contents, fmt, args);
        stderr.print(KNRM ++ "\n\n", .{}) catch {};
        return error.Failed;
    };
    // display the problematic line
    // look backward for newline.
    var i: usize = source_range.loc0.index;
    while (i > 0) {
        i -= 1;
        if (source.contents[i] == '\n') {
            i += 1;
            break;
        }
    }
    const start = i;
    // look forward for newline.
    i = source_range.loc0.index;
    while (i < source.contents.len) {
        if (source.contents[i] == '\n' or source.contents[i] == '\r') {
            break;
        }
        i += 1;
    }
    const end = i;
    const col = source_range.loc0.index - start;
    // ok
    const held = std.debug.getStderrMutex().acquire();
    defer held.release();
    const stderr = std.debug.getStderrStream();
    stderr.print(KYEL ++ KBOLD ++ "{}:{}:{}: " ++ KWHITE, .{
        source.filename,
        source_range.loc0.line + 1,
        col + 1,
    }) catch {};
    failPrint(stderr, source.contents, fmt, args);
    stderr.print(KNRM ++ "\n\n", .{}) catch {};
    // display line
    stderr.print("{}\n", .{source.contents[start..end]}) catch {};
    // show arrow pointing at column
    i = 0;
    while (i < col) : (i += 1) {
        stderr.print(" ", .{}) catch {};
    }
    stderr.write(KRED ++ KBOLD) catch {};
    while (i < end - start and i < source_range.loc1.index - start) : (i += 1) {
        stderr.print("^", .{}) catch {};
    }
    stderr.write(KNRM) catch {};
    stderr.print("\n", .{}) catch {};
    return error.Failed;
}

pub const Parser = struct {
    source: Source,
    tokens: []const Token,
    i: usize,

    pub fn next(self: *Parser) ?Token {
        if (self.i < self.tokens.len) {
            defer self.i += 1;
            return self.tokens[self.i];
        }
        return null;
    }

    pub fn peek(self: *Parser) ?Token {
        if (self.i < self.tokens.len) {
            return self.tokens[self.i];
        }
        return null;
    }

    pub fn expect(self: *Parser) !Token {
        // FIXME can i have it print what it was looking for?
        // or maybe make EOF a kind of token?
        return self.next() orelse {
            return fail(self.source, null, "unexpected end of file", .{});
        };
    }

    pub fn expectIdentifier(self: *Parser) ![]const u8 {
        const token = try self.expect();
        switch (token.tt) {
            .identifier => return self.source.contents[token.source_range.loc0.index..token.source_range.loc1.index],
            else => return fail(self.source, token.source_range, "expected identifier, found `%`", .{token.source_range}),
        }
    }

    // this is not great because we don't have a stringifier, and the function
    // wouldn't be useful if caller wanted e.g. one of two symbols
    // (e.g. `,` or `)` in function args)
    //pub fn expectSymbol(self: *Parser, expected: var) !void {
    //    const found = try self.expect();
    //    if (found.tt != expected) {
    //        return fail(self.source, found, "expected `%`, found `%`", .{
    //            expected,
    //            found.tt,
    //        });
    //    }
    //}

    pub fn peekSymbol(self: *Parser, expected: var) bool {
        if (self.peek()) |found| {
            return found.tt == expected;
        }
        return false;
    }
};
