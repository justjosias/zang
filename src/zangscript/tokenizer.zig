const std = @import("std");
const fail = @import("fail.zig").fail;

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

pub const TokenType = enum {
    illegal,
    sym_asterisk,
    sym_colon,
    sym_comma,
    sym_dbl_asterisk,
    sym_equals,
    sym_left_paren,
    sym_minus,
    sym_plus,
    sym_right_paren,
    kw_begin,
    kw_def,
    kw_delay,
    kw_end,
    kw_false,
    kw_feedback,
    kw_let,
    kw_out,
    kw_true,
    identifier,
    enum_value,
    number,
};

pub const Token = struct {
    source_range: SourceRange,
    tt: TokenType,
};

fn addToken(tokens: *std.ArrayList(Token), loc0: SourceLocation, loc1: SourceLocation, tt: TokenType) !void {
    try tokens.append(.{
        .source_range = .{ .loc0 = loc0, .loc1 = loc1 },
        .tt = tt,
    });
}

pub fn tokenize(source: Source, allocator: *std.mem.Allocator) ![]const Token {
    var tokens = std.ArrayList(Token).init(allocator);
    errdefer tokens.deinit();

    const src = source.contents;
    var loc: SourceLocation = .{
        .line = 0,
        .index = 0,
    };
    while (true) {
        while (loc.index < src.len and isWhitespace(src[loc.index])) {
            if (src[loc.index] == '\r') {
                loc.index += 1;
                if (loc.index == src.len or src[loc.index] != '\n') {
                    loc.line += 1;
                    continue;
                }
            }
            if (src[loc.index] == '\n') {
                loc.line += 1;
            }
            loc.index += 1;
        }
        if (loc.index + 2 < src.len and src[loc.index] == '/' and src[loc.index + 1] == '/') {
            while (loc.index < src.len and src[loc.index] != '\r' and src[loc.index] != '\n') {
                loc.index += 1;
            }
            continue;
        }
        if (loc.index == src.len) {
            break;
        }
        const start = loc;
        if (getSymbol(src[loc.index..])) |result| {
            loc.index += result.len;
            try addToken(&tokens, start, loc, result.tt);
            continue;
        }
        if (src[loc.index] == '\'') {
            loc.index += 1;
            const start2 = loc;
            while (true) {
                if (loc.index == src.len or src[loc.index] == '\r' or src[loc.index] == '\n') {
                    const sr: SourceRange = .{ .loc0 = start, .loc1 = loc };
                    return fail(source, sr, "expected closing `'`, found end of line", .{});
                }
                if (src[loc.index] == '\'') {
                    break;
                }
                loc.index += 1;
            }
            if (loc.index == start2.index) {
                // the reason i catch this here is that the quotes are not included in the
                // enum literal token. and if i let an empty value through, there will be
                // no characters to underline in further compile errors. whereas here we
                // know about the quote characters and can include them in the underlining
                loc.index += 1;
                const sr: SourceRange = .{ .loc0 = start, .loc1 = loc };
                return fail(source, sr, "enum literal cannot be empty", .{});
            }
            try addToken(&tokens, start2, loc, .enum_value);
            loc.index += 1;
            continue;
        }
        if (getNumber(src[loc.index..])) |len| {
            loc.index += len;
            try addToken(&tokens, start, loc, .number);
            continue;
        }
        if (getIdentifier(src[loc.index..])) |len| {
            loc.index += len;
            const string = src[start.index..loc.index];
            const tt = getKeyword(string) orelse .identifier;
            try addToken(&tokens, start, loc, tt);
            continue;
        }
        loc.index += 1;
        try addToken(&tokens, start, loc, .illegal);
    }

    return tokens.toOwnedSlice();
}

inline fn isWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

inline fn isStartOfIdentifier(ch: u8) bool {
    // note that unlike in C, identifiers cannot start with an underscore
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
}

inline fn isIdentifierInterior(ch: u8) bool {
    return isStartOfIdentifier(ch) or (ch >= '0' and ch <= '9') or ch == '_';
}

fn getIdentifier(string: []const u8) ?usize {
    if (isStartOfIdentifier(string[0])) {
        var i: usize = 1;
        while (i < string.len and isIdentifierInterior(string[i])) {
            i += 1;
        }
        return i;
    }
    return null;
}

fn getNumber(string: []const u8) ?usize {
    if (string[0] >= '0' and string[0] <= '9') {
        var i: usize = 1;
        while (i < string.len and ((string[i] >= '0' and string[i] <= '9') or string[i] == '.')) {
            i += 1;
        }
        return i;
    }
    return null;
}

const GetSymbolResult = struct { tt: TokenType, len: usize };

fn getSymbol(string: []const u8) ?GetSymbolResult {
    const symbols = [_]struct { string: []const u8, tt: TokenType }{
        .{ .string = "**", .tt = .sym_dbl_asterisk },
        .{ .string = "*", .tt = .sym_asterisk },
        .{ .string = ":", .tt = .sym_colon },
        .{ .string = ":", .tt = .sym_colon },
        .{ .string = ",", .tt = .sym_comma },
        .{ .string = "=", .tt = .sym_equals },
        .{ .string = "(", .tt = .sym_left_paren },
        .{ .string = "-", .tt = .sym_minus },
        .{ .string = "+", .tt = .sym_plus },
        .{ .string = ")", .tt = .sym_right_paren },
    };
    for (symbols) |symbol| {
        if (std.mem.startsWith(u8, string, symbol.string)) {
            return GetSymbolResult{ .tt = symbol.tt, .len = symbol.string.len };
        }
    }
    return null;
}

fn getKeyword(string: []const u8) ?TokenType {
    const keywords = [_]struct { string: []const u8, tt: TokenType }{
        .{ .string = "begin", .tt = .kw_begin },
        .{ .string = "def", .tt = .kw_def },
        .{ .string = "delay", .tt = .kw_delay },
        .{ .string = "end", .tt = .kw_end },
        .{ .string = "false", .tt = .kw_false },
        .{ .string = "feedback", .tt = .kw_feedback },
        .{ .string = "let", .tt = .kw_let },
        .{ .string = "out", .tt = .kw_out },
        .{ .string = "true", .tt = .kw_true },
    };
    for (keywords) |keyword| {
        if (std.mem.eql(u8, string, keyword.string)) {
            return keyword.tt;
        }
    }
    return null;
}

pub const TokenIterator = struct {
    source: Source,
    tokens: []const Token,
    i: usize,

    pub fn init(source: Source, tokens: []const Token) TokenIterator {
        return .{
            .source = source,
            .tokens = tokens,
            .i = 0,
        };
    }

    pub fn next(self: *TokenIterator) ?Token {
        if (self.i < self.tokens.len) {
            defer self.i += 1;
            return self.tokens[self.i];
        }
        return null;
    }

    pub fn peek(self: *TokenIterator) ?Token {
        if (self.i < self.tokens.len) {
            return self.tokens[self.i];
        }
        return null;
    }

    pub fn expect(self: *TokenIterator) !Token {
        // FIXME can i have it print what it was looking for?
        // or maybe make EOF a kind of token?
        return self.next() orelse return fail(self.source, null, "unexpected end of file", .{});
    }
};
