const std = @import("std");
const Token = @import("tokenizer.zig").Token;
const TokenType = @import("tokenizer.zig").TokenType;

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

fn printToken(stderr: var, tt: TokenType) void {
    // TODO i could get rid of this if i had the tokens track start and end pos
    // then i could just print out the span
    (switch (tt) {
        .sym_at => noasync stderr.writeByte('@'),
        .sym_colon => noasync stderr.writeByte(':'),
        .sym_comma => noasync stderr.writeByte(','),
        .sym_left_paren => noasync stderr.writeByte('('),
        .sym_right_paren => noasync stderr.writeByte(')'),
        .sym_semicolon => noasync stderr.writeByte(';'),
        .kw_begin => noasync stderr.write("begin"),
        .kw_def => noasync stderr.write("def"),
        .kw_end => noasync stderr.write("end"),
        .identifier => |identifier| noasync stderr.write(identifier),
        .number => |number| noasync stderr.print("{d}", .{ number }),
    }) catch {};
}

fn failPrint(stderr: var, comptime fmt: []const u8, args: var) void {
    comptime var j: usize = 0;
    inline for (fmt) |ch| {
        if (ch == '%') {
            // token
            printToken(stderr, args[j]);
            j += 1;
        } else if (ch == '#') {
            // string
            noasync stderr.write(args[j]) catch {};
        } else {
            noasync stderr.writeByte(ch) catch {};
        }
    }
}

pub fn fail(
    source: Source,
    maybe_loc: ?SourceLocation,
    comptime fmt: []const u8,
    args: var,
) error{Failed} {
    const loc = maybe_loc orelse {
        const held = std.debug.getStderrMutex().acquire();
        defer held.release();
        const stderr = std.debug.getStderrStream();
        noasync stderr.print("{}: ", .{ source.filename }) catch {};
        failPrint(stderr, fmt, args);
        noasync stderr.print("\n\n", .{}) catch {};
        return error.Failed;
    };
    // display the problematic line
    // look backward for newline.
    var i: usize = loc.index;
    while (i > 0) {
        i -= 1;
        if (source.contents[i] == '\n') {
            i += 1;
            break;
        }
    }
    const start = i;
    // look forward for newline.
    i = loc.index;
    while (i < source.contents.len) {
        if (source.contents[i] == '\n' or source.contents[i] == '\r') {
            break;
        }
        i += 1;
    }
    const end = i;
    const col = loc.index - start;
    // ok
    const held = std.debug.getStderrMutex().acquire();
    defer held.release();
    const stderr = std.debug.getStderrStream();
    noasync stderr.print("{}:{}:{}: ", .{
        source.filename,
        loc.line + 1,
        col + 1,
    }) catch {};
    failPrint(stderr, fmt, args);
    noasync stderr.print("\n\n", .{}) catch {};
    // display line
    noasync stderr.print("{}\n", .{ source.contents[start..end] }) catch {};
    // show arrow pointing at column
    i = 0; while (i < col) : (i += 1) {
        noasync stderr.print(" ", .{}) catch {};
    }
    noasync stderr.print("^\n", .{}) catch {};
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
            .identifier => |identifier| return identifier,
            else => {
                return fail(
                    self.source,
                    token.loc,
                    "expected identifier, found `%`",
                    .{ token.tt },
                );
            },
        }
    }

    pub fn expectSymbol(self: *Parser, expected: var) !void {
        const found = try self.expect();
        if (found.tt != expected) {
            return fail(self.source, found.loc, "expected `%`, found `%`", .{
                expected,
                found.tt,
            });
        }
    }

    pub fn peekSymbol(self: *Parser, expected: var) bool {
        if (self.peek()) |found| {
            return found.tt == expected;
        }
        return false;
    }
};
