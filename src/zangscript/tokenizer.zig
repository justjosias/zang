const std = @import("std");
const Source = @import("common.zig").Source;
const SourceLocation = @import("common.zig").SourceLocation;
const SourceRange = @import("common.zig").SourceRange;
const fail = @import("common.zig").fail;

pub const TokenType = enum {
    sym_asterisk,
    sym_at,
    sym_colon,
    sym_comma,
    sym_dollar,
    sym_equals,
    sym_left_paren,
    sym_plus,
    sym_right_paren,
    sym_semicolon,
    kw_begin,
    kw_def,
    kw_delay,
    kw_end,
    kw_false,
    kw_feedback,
    kw_let,
    kw_out,
    kw_param,
    kw_true,
    identifier,
    enum_value,
    number,
};

pub const Token = struct {
    source_range: SourceRange,
    tt: TokenType,
};

inline fn isWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\r' or ch == '\n';
}

inline fn isStartOfIdentifier(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
}

inline fn isIdentifierInterior(ch: u8) bool {
    return isStartOfIdentifier(ch) or (ch >= '0' and ch <= '9');
}

pub const Tokenizer = struct {
    source: Source,
    error_message: ?[]const u8,
    tokens: std.ArrayList(Token),
};

fn addToken(tokenizer: *Tokenizer, loc0: SourceLocation, loc1: SourceLocation, tt: TokenType) !void {
    try tokenizer.tokens.append(.{
        .source_range = .{
            .loc0 = loc0,
            .loc1 = loc1,
        },
        .tt = tt,
    });
}

pub fn tokenize(tokenizer: *Tokenizer) !void {
    const src = tokenizer.source.contents;
    var loc: SourceLocation = .{
        .line = 0,
        .index = 0,
    };
    while (true) {
        while (loc.index < src.len and isWhitespace(src[loc.index])) {
            // FIXME handle lone \r
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
        if (src[loc.index] == '*') {
            loc.index += 1;
            try addToken(tokenizer, start, loc, .sym_asterisk);
            continue;
        }
        if (src[loc.index] == '@') {
            loc.index += 1;
            try addToken(tokenizer, start, loc, .sym_at);
            continue;
        }
        if (src[loc.index] == ':') {
            loc.index += 1;
            try addToken(tokenizer, start, loc, .sym_colon);
            continue;
        }
        if (src[loc.index] == ',') {
            loc.index += 1;
            try addToken(tokenizer, start, loc, .sym_comma);
            continue;
        }
        if (src[loc.index] == '$') {
            loc.index += 1;
            try addToken(tokenizer, start, loc, .sym_dollar);
            continue;
        }
        if (src[loc.index] == '=') {
            loc.index += 1;
            try addToken(tokenizer, start, loc, .sym_equals);
            continue;
        }
        if (src[loc.index] == '(') {
            loc.index += 1;
            try addToken(tokenizer, start, loc, .sym_left_paren);
            continue;
        }
        if (src[loc.index] == '+') {
            loc.index += 1;
            try addToken(tokenizer, start, loc, .sym_plus);
            continue;
        }
        if (src[loc.index] == ')') {
            loc.index += 1;
            try addToken(tokenizer, start, loc, .sym_right_paren);
            continue;
        }
        if (src[loc.index] == ';') {
            loc.index += 1;
            try addToken(tokenizer, start, loc, .sym_semicolon);
            continue;
        }
        if (src[loc.index] == '\'') {
            loc.index += 1;
            const start2 = loc;
            while (loc.index < src.len and src[loc.index] != '\'') {
                loc.index += 1;
            }
            if (loc.index == src.len) {
                return fail(tokenizer.source, null, "expected `'`, found end of file", .{});
            }
            // TODO check value for illegal characters (e.g. newlines)
            try addToken(tokenizer, start2, loc, .enum_value);
            loc.index += 1;
            continue;
        }
        if (src[loc.index] >= '0' and src[loc.index] <= '9') {
            loc.index += 1;
            while (loc.index < src.len and
                ((src[loc.index] >= '0' and src[loc.index] <= '9') or src[loc.index] == '.'))
            {
                loc.index += 1;
            }
            try addToken(tokenizer, start, loc, .number);
            continue;
        }
        if (!isStartOfIdentifier(src[loc.index])) {
            loc.index += 1;
            const source_range: SourceRange = .{
                .loc0 = start,
                .loc1 = loc,
            };
            return fail(tokenizer.source, source_range, "illegal character: `%`", .{source_range});
        }
        loc.index += 1;
        while (loc.index < src.len and isIdentifierInterior(src[loc.index])) {
            loc.index += 1;
        }
        const token = src[start.index..loc.index];
        if (std.mem.eql(u8, token, "begin")) {
            try addToken(tokenizer, start, loc, .kw_begin);
        } else if (std.mem.eql(u8, token, "def")) {
            try addToken(tokenizer, start, loc, .kw_def);
        } else if (std.mem.eql(u8, token, "delay")) {
            try addToken(tokenizer, start, loc, .kw_delay);
        } else if (std.mem.eql(u8, token, "end")) {
            try addToken(tokenizer, start, loc, .kw_end);
        } else if (std.mem.eql(u8, token, "false")) {
            try addToken(tokenizer, start, loc, .kw_false);
        } else if (std.mem.eql(u8, token, "feedback")) {
            try addToken(tokenizer, start, loc, .kw_feedback);
        } else if (std.mem.eql(u8, token, "let")) {
            try addToken(tokenizer, start, loc, .kw_let);
        } else if (std.mem.eql(u8, token, "out")) {
            try addToken(tokenizer, start, loc, .kw_out);
        } else if (std.mem.eql(u8, token, "param")) {
            try addToken(tokenizer, start, loc, .kw_param);
        } else if (std.mem.eql(u8, token, "true")) {
            try addToken(tokenizer, start, loc, .kw_true);
        } else {
            try addToken(tokenizer, start, loc, .identifier);
        }
    }
}
