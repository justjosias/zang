const std = @import("std");
const Source = @import("common.zig").Source;
const SourceLocation = @import("common.zig").SourceLocation;
const fail = @import("common.zig").fail;

pub const TokenType = union(enum) {
    sym_at,
    sym_colon,
    sym_comma,
    sym_left_paren,
    sym_right_paren,
    sym_semicolon,
    kw_begin,
    kw_def,
    kw_end,
    identifier: []const u8,
    number: f32,
};

pub const Token = struct {
    tt: TokenType,
    loc: SourceLocation,
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

fn addToken(tokenizer: *Tokenizer, loc: SourceLocation, tt: TokenType) !void {
    try tokenizer.tokens.append(.{
        .tt = tt,
        .loc = loc,
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
        if (loc.index == src.len) {
            break;
        }
        if (src[loc.index] == '@') {
            try addToken(tokenizer, loc, .sym_at);
            loc.index += 1;
            continue;
        }
        if (src[loc.index] == ':') {
            try addToken(tokenizer, loc, .sym_colon);
            loc.index += 1;
            continue;
        }
        if (src[loc.index] == ',') {
            try addToken(tokenizer, loc, .sym_comma);
            loc.index += 1;
            continue;
        }
        if (src[loc.index] == '(') {
            try addToken(tokenizer, loc, .sym_left_paren);
            loc.index += 1;
            continue;
        }
        if (src[loc.index] == ')') {
            try addToken(tokenizer, loc, .sym_right_paren);
            loc.index += 1;
            continue;
        }
        if (src[loc.index] == ';') {
            try addToken(tokenizer, loc, .sym_semicolon);
            loc.index += 1;
            continue;
        }
        if (src[loc.index] >= '0' and src[loc.index] <= '9') {
            const start = loc;
            loc.index += 1;
            while (loc.index < src.len and
                    ((src[loc.index] >= '0' and src[loc.index] <= '9')
                     or src[loc.index] == '.')) {
                loc.index += 1;
            }
            const number =
                try std.fmt.parseFloat(f32, src[start.index..loc.index]);
            try addToken(tokenizer, start, .{ .number = number });
            continue;
        }
        if (!isStartOfIdentifier(src[loc.index])) {
            return fail(tokenizer.source, loc, "illegal character: `#`", .{
                src[loc.index..loc.index + 1],
            });
        }
        const start = loc;
        loc.index += 1;
        while (loc.index < src.len and isIdentifierInterior(src[loc.index])) {
            loc.index += 1;
        }
        const token = src[start.index..loc.index];
        if (std.mem.eql(u8, token, "begin")) {
            try addToken(tokenizer, start, .kw_begin);
        } else if (std.mem.eql(u8, token, "def")) {
            try addToken(tokenizer, start, .kw_def);
        } else if (std.mem.eql(u8, token, "end")) {
            try addToken(tokenizer, start, .kw_end);
        } else {
            try addToken(tokenizer, start, .{ .identifier = token });
        }
    }
}
