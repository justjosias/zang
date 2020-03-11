const std = @import("std");
const Source = @import("common.zig").Source;
const SourceLocation = @import("common.zig").SourceLocation;
const fail = @import("common.zig").fail;

pub const TokenType = union(enum) {
    illegal,
    sym_at,
    sym_colon,
    sym_comma,
    sym_left_paren,
    sym_right_paren,
    sym_semicolon,
    kw_begin,
    kw_def,
    kw_end,
    kw_false,
    kw_param,
    kw_true,
    identifier: []const u8,
    number: f32,
};

pub const Token = struct {
    tt: TokenType,
    loc0: SourceLocation, // start
    loc1: SourceLocation, // end
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
        .tt = tt,
        .loc0 = loc0,
        .loc1 = loc1,
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
        if (src[loc.index] == '(') {
            loc.index += 1;
            try addToken(tokenizer, start, loc, .sym_left_paren);
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
        if (src[loc.index] >= '0' and src[loc.index] <= '9') {
            loc.index += 1;
            while (loc.index < src.len and
                ((src[loc.index] >= '0' and src[loc.index] <= '9') or src[loc.index] == '.'))
            {
                loc.index += 1;
            }
            const number = try std.fmt.parseFloat(f32, src[start.index..loc.index]);
            try addToken(tokenizer, start, loc, .{ .number = number });
            continue;
        }
        if (!isStartOfIdentifier(src[loc.index])) {
            loc.index += 1;
            const token: Token = .{
                .tt = .illegal,
                .loc0 = start,
                .loc1 = loc,
            };
            return fail(tokenizer.source, token, "illegal character: `%`", .{token});
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
        } else if (std.mem.eql(u8, token, "end")) {
            try addToken(tokenizer, start, loc, .kw_end);
        } else if (std.mem.eql(u8, token, "false")) {
            try addToken(tokenizer, start, loc, .kw_false);
        } else if (std.mem.eql(u8, token, "param")) {
            try addToken(tokenizer, start, loc, .kw_param);
        } else if (std.mem.eql(u8, token, "true")) {
            try addToken(tokenizer, start, loc, .kw_true);
        } else {
            try addToken(tokenizer, start, loc, .{ .identifier = token });
        }
    }
}
