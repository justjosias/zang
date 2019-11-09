const std = @import("std");

pub fn Parser(comptime num_columns: usize) type {
    return struct {
        pub const Note = union(enum) {
            Idle: void,
            Freq: f32,
            Off: void,
        };

        pub const Token = union(enum) {
            Word: []const u8,
            Number: f32,
            Notes: [num_columns]Note,

            fn isWord(token: Token, word: []const u8) bool {
                return switch (token) {
                    .Word => |s| std.mem.eql(u8, word, s),
                    else => false,
                };
            }
        };

        a4: f32,
        contents: []const u8,
        index: usize,
        line_index: usize,

        fn parseNote(parser: *@This()) ?f32 {
            if (parser.index + 3 > parser.contents.len) {
                return null;
            }

            const letter = parser.contents[parser.index];
            const modifier = parser.contents[parser.index + 1];
            const octave = parser.contents[parser.index + 2];

            const offset =
                if (octave >= '0' and octave <= '9')
                    @intCast(i32, octave - '0') * 12 - 57
                else
                    return null;

            const semitone = blk: {
                if (letter == 'C' and modifier == '-') break :blk @as(i32, 0);
                if (letter == 'C' and modifier == '#') break :blk @as(i32, 1);
                if (letter == 'D' and modifier == '-') break :blk @as(i32, 2);
                if (letter == 'D' and modifier == '#') break :blk @as(i32, 3);
                if (letter == 'E' and modifier == '-') break :blk @as(i32, 4);
                if (letter == 'F' and modifier == '-') break :blk @as(i32, 5);
                if (letter == 'F' and modifier == '#') break :blk @as(i32, 6);
                if (letter == 'G' and modifier == '-') break :blk @as(i32, 7);
                if (letter == 'G' and modifier == '#') break :blk @as(i32, 8);
                if (letter == 'A' and modifier == '-') break :blk @as(i32, 9);
                if (letter == 'A' and modifier == '#') break :blk @as(i32, 10);
                if (letter == 'B' and modifier == '-') break :blk @as(i32, 11);
                return null;
            };

            parser.index += 3;

            return parser.a4 * std.math.pow(f32, 2.0, @intToFloat(f32, offset + semitone) / 12.0);
        }

        pub fn parseToken(parser: *@This()) !?Token {
            while (true) {
                if (parser.index < parser.contents.len and parser.contents[parser.index] == ' ') {
                    parser.index += 1;
                } else if (parser.index < parser.contents.len and parser.contents[parser.index] == '\n') {
                    parser.line_index += 1;
                    parser.index += 1;
                } else if (parser.index < parser.contents.len and parser.contents[parser.index] == '#') {
                    parser.index += 1;
                    while (parser.index < parser.contents.len and parser.contents[parser.index] != '\n') {
                        parser.index += 1;
                    }
                    if (parser.index < parser.contents.len) {
                        parser.line_index += 1;
                        parser.index += 1;
                    }
                } else {
                    break;
                }
            }

            if (parser.index >= parser.contents.len) {
                return null;
            }

            const ch = parser.contents[parser.index];

            if (ch == '|') {
                parser.index += 1;

                var notes = [1]Note { Note.Idle } ** num_columns;

                var col: usize = 0; while (true) : (col += 1) {
                    if (col >= num_columns) {
                        return error.SyntaxError;
                    }
                    if (parseNote(parser)) |freq| {
                        notes[col] = Note { .Freq = freq };
                    } else if (parser.index + 3 <= parser.contents.len and std.mem.eql(u8, parser.contents[parser.index .. parser.index + 3], "off")) {
                        notes[col] = Note.Off;
                        parser.index += 3;
                    } else if (parser.index + 3 <= parser.contents.len and std.mem.eql(u8, parser.contents[parser.index .. parser.index + 3], "   ")) {
                        parser.index += 3;
                    } else {
                        break;
                    }
                    if (parser.index < parser.contents.len and (parser.contents[parser.index] == ' ' or parser.contents[parser.index] == '|')) {
                        parser.index += 1;
                    } else {
                        break;
                    }
                }

                if (parser.index < parser.contents.len) {
                    if (parser.contents[parser.index] == '\n') {
                        parser.line_index += 1;
                        parser.index += 1;
                    } else {
                        return error.SyntaxError;
                    }
                }

                return Token { .Notes = notes };
            }

            if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_') {
                const start = parser.index;
                parser.index += 1;
                while (parser.index < parser.contents.len) {
                    const ch2 = parser.contents[parser.index];
                    if ((ch2 >= 'a' and ch2 <= 'z') or (ch2 >= 'A' and ch2 <= 'Z') or (ch2 >= '0' and ch2 <= '9') or ch2 == '_') {
                        parser.index += 1;
                    } else {
                        break;
                    }
                }
                return Token { .Word = parser.contents[start..parser.index] };
            }

            if (ch >= '0' and ch <= '9') {
                const start = parser.index;
                var dot = false;
                parser.index += 1;
                while (parser.index < parser.contents.len) {
                    const ch2 = parser.contents[parser.index];
                    if (ch2 == '.') {
                        if (dot) {
                            break;
                        } else {
                            dot = true;
                            parser.index += 1;
                        }
                    } else if (ch2 >= '0' and ch2 <= '9') {
                        parser.index += 1;
                    } else {
                        break;
                    }
                }
                const number = try std.fmt.parseFloat(f32, parser.contents[start..parser.index]);
                return Token { .Number = number };
            }

            return error.SyntaxError;
        }

        fn requireToken(parser: *@This()) !Token {
            return (try parser.parseToken()) orelse error.UnexpectedEof;
        }

        fn requireNumber(parser: *@This()) !f32 {
            return switch (try parser.requireToken()) {
                .Number => |n| n,
                else => error.ExpectedNumber,
            };
        }
    };
}
