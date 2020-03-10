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

fn printToken(stderr: var, contents: []const u8, token: Token) void {
    // TODO would be nice if it could say "keyword `param`" instead of just "`param`"
    // first i need to move the backquotes into here...
    stderr.write(contents[token.loc0.index..token.loc1.index]) catch {};
}

fn failPrint(stderr: var, contents: []const u8, comptime fmt: []const u8, args: var) void {
    comptime var j: usize = 0;
    inline for (fmt) |ch| {
        if (ch == '%') {
            // token
            printToken(stderr, contents, args[j]);
            j += 1;
        } else if (ch == '#') {
            // string
            stderr.write(args[j]) catch {};
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
    maybe_token: ?Token,
    comptime fmt: []const u8,
    args: var,
) error{Failed} {
    const token = maybe_token orelse {
        const held = std.debug.getStderrMutex().acquire();
        defer held.release();
        const stderr = std.debug.getStderrStream();
        stderr.print("{}: ", .{ source.filename }) catch {};
        failPrint(stderr, source.contents, fmt, args);
        stderr.print("\n\n", .{}) catch {};
        return error.Failed;
    };
    // display the problematic line
    // look backward for newline.
    var i: usize = token.loc0.index;
    while (i > 0) {
        i -= 1;
        if (source.contents[i] == '\n') {
            i += 1;
            break;
        }
    }
    const start = i;
    // look forward for newline.
    i = token.loc0.index;
    while (i < source.contents.len) {
        if (source.contents[i] == '\n' or source.contents[i] == '\r') {
            break;
        }
        i += 1;
    }
    const end = i;
    const col = token.loc0.index - start;
    // ok
    const held = std.debug.getStderrMutex().acquire();
    defer held.release();
    const stderr = std.debug.getStderrStream();
    stderr.print(KYEL ++ KBOLD ++ "{}:{}:{}: " ++ KWHITE, .{
        source.filename,
        token.loc0.line + 1,
        col + 1,
    }) catch {};
    failPrint(stderr, source.contents, fmt, args);
    stderr.print(KNRM ++ "\n\n", .{}) catch {};
    // display line
    stderr.print("{}\n", .{ source.contents[start..end] }) catch {};
    // show arrow pointing at column
    i = 0; while (i < col) : (i += 1) {
        stderr.print(" ", .{}) catch {};
    }
    stderr.write(KRED ++ KBOLD) catch {};
    while (i < end - start and i < token.loc1.index - start) : (i += 1) {
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
            .identifier => |identifier| return identifier,
            else => {
                return fail(
                    self.source,
                    token,
                    "expected identifier, found `%`",
                    .{ token },
                );
            },
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
