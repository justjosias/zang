const std = @import("std");
const fail = @import("fail.zig").fail;

pub const Source = struct {
    filename: []const u8,
    contents: []const u8,

    pub fn getString(self: Source, source_range: SourceRange) []const u8 {
        return self.contents[source_range.loc0.index..source_range.loc1.index];
    }
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

pub const Tokenizer = struct {
    source: Source,
    loc: SourceLocation,

    pub fn init(source: Source) Tokenizer {
        return .{
            .source = source,
            .loc = .{ .line = 0, .index = 0 },
        };
    }

    fn makeToken(loc0: SourceLocation, loc1: SourceLocation, tt: TokenType) Token {
        return .{
            .source_range = .{ .loc0 = loc0, .loc1 = loc1 },
            .tt = tt,
        };
    }

    pub fn next(self: *Tokenizer) !?Token {
        const src = self.source.contents;

        var loc = self.loc;
        defer self.loc = loc;

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
                return makeToken(start, loc, result.tt);
            }
            if (src[loc.index] == '\'') {
                loc.index += 1;
                const start2 = loc;
                while (true) {
                    if (loc.index == src.len or src[loc.index] == '\r' or src[loc.index] == '\n') {
                        const sr: SourceRange = .{ .loc0 = start, .loc1 = loc };
                        return fail(self.source, sr, "expected closing `'`, found end of line", .{});
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
                    return fail(self.source, sr, "enum literal cannot be empty", .{});
                }
                const token = makeToken(start2, loc, .enum_value);
                loc.index += 1;
                return token;
            }
            if (getNumber(src[loc.index..])) |len| {
                loc.index += len;
                return makeToken(start, loc, .number);
            }
            if (getIdentifier(src[loc.index..])) |len| {
                loc.index += len;
                const string = src[start.index..loc.index];
                const tt = getKeyword(string) orelse .identifier;
                return makeToken(start, loc, tt);
            }
            loc.index += 1;
            return makeToken(start, loc, .illegal);
        }
        return null;
    }

    pub fn peek(self: *Tokenizer) !?Token {
        const loc = self.loc;
        defer self.loc = loc;

        return try self.next();
    }

    pub fn failExpected(self: *Tokenizer, desc: []const u8, found: SourceRange) error{Failed} {
        return fail(self.source, found, "expected #, found `<`", .{desc});
    }

    pub fn expect(self: *Tokenizer, desc: []const u8) !Token {
        const token = try self.next();
        return token orelse fail(self.source, null, "expected #, found end of file", .{desc});
    }

    pub fn expectIdentifier(self: *Tokenizer, desc: []const u8) !Token {
        const token = try self.expect(desc);
        if (token.tt != .identifier) {
            return self.failExpected(desc, token.source_range);
        }
        return token;
    }

    pub fn expectOneOf(self: *Tokenizer, comptime tts: []const TokenType) !Token {
        comptime var desc: []const u8 = "";
        inline for (tts) |tt, i| {
            if (i > 0) desc = desc ++ ", ";
            desc = desc ++ describeTokenType(tt);
        }
        const token = try self.expect(desc);
        for (tts) |tt| {
            if (token.tt == tt) {
                return token;
            }
        }
        return self.failExpected(desc, token.source_range);
    }
};

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

fn describeTokenType(tt: TokenType) []const u8 {
    return switch (tt) {
        .illegal => "(illegal)",
        .sym_asterisk => "`*`",
        .sym_colon => "`:`",
        .sym_comma => "`,`",
        .sym_dbl_asterisk => "`**`",
        .sym_equals => "`=`",
        .sym_left_paren => "`(`",
        .sym_minus => "`-`",
        .sym_plus => "`+`",
        .sym_right_paren => "`)`",
        .kw_begin => "`begin`",
        .kw_def => "`def`",
        .kw_delay => "`delay`",
        .kw_end => "`end`",
        .kw_false => "`false`",
        .kw_feedback => "`feedback`",
        .kw_let => "`let`",
        .kw_out => "`out`",
        .kw_true => "`true`",
        .identifier => "identifier",
        .enum_value => "enum value",
        .number => "number",
    };
}
