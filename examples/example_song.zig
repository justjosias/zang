const std = @import("std");
const zang = @import("zang");
const f = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/c.zig");
const Instrument = @import("modules.zig").SquareWithEnvelope;

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 4096;

pub const DESCRIPTION =
    c\\example_song
    c\\
    c\\Plays a canned melody (Bach's Toccata and Fugue in D
    c\\Minor).
    c\\
    c\\Press spacebar to restart the song.
;

const A4 = 440.0;
const NOTE_DURATION = 0.15;
const NUM_TRACKS_1 = 9; // normal keys
const NUM_TRACKS_2 = 2; // weird keys
const TOTAL_TRACKS = NUM_TRACKS_1 + NUM_TRACKS_2;

const MyNoteParams = struct {
    freq: f32,
    note_on: bool,
};

const Note = union(enum) {
    Idle: void,
    Freq: f32,
    Off: void,
};

const Token = union(enum) {
    Word: []const u8,
    Number: f32,
    Notes: [TOTAL_TRACKS]Note,
};

const Parser = struct {
    contents: []const u8,
    index: usize,
    line_index: usize,
};

fn parseNote(parser: *Parser) ?MyNoteParams {
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
        if (letter == 'C' and modifier == '-') break :blk i32(0);
        if (letter == 'C' and modifier == '#') break :blk i32(1);
        if (letter == 'D' and modifier == '-') break :blk i32(2);
        if (letter == 'D' and modifier == '#') break :blk i32(3);
        if (letter == 'E' and modifier == '-') break :blk i32(4);
        if (letter == 'F' and modifier == '-') break :blk i32(5);
        if (letter == 'F' and modifier == '#') break :blk i32(6);
        if (letter == 'G' and modifier == '-') break :blk i32(7);
        if (letter == 'G' and modifier == '#') break :blk i32(8);
        if (letter == 'A' and modifier == '-') break :blk i32(9);
        if (letter == 'A' and modifier == '#') break :blk i32(10);
        if (letter == 'B' and modifier == '-') break :blk i32(11);
        return null;
    };

    parser.index += 3;

    return MyNoteParams {
        .freq = A4 * std.math.pow(f32, 2.0, @intToFloat(f32, offset + semitone) / 12.0),
        .note_on = true,
    };
}

fn parseToken(parser: *Parser) !?Token {
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

        var notes = [1]Note { Note { .Idle = undefined } } ** TOTAL_TRACKS;

        var col: usize = 0; while (true) : (col += 1) {
            if (parseNote(parser)) |note_params| {
                notes[col] = Note { .Freq = note_params.freq };
            } else if (parser.index + 3 <= parser.contents.len and std.mem.eql(u8, parser.contents[parser.index .. parser.index + 3], "off")) {
                notes[col] = Note { .Off = undefined };
                parser.index += 3;
            } else if (parser.index + 3 <= parser.contents.len and std.mem.eql(u8, parser.contents[parser.index .. parser.index + 3], "   ")) {
                parser.index += 3;
            } else {
                break;
            }
            if (parser.index < parser.contents.len and parser.contents[parser.index] == ' ') {
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

var result_arr: [TOTAL_TRACKS][9999]zang.Notes(MyNoteParams).SongNote = undefined;
var tracks: [TOTAL_TRACKS][]zang.Notes(MyNoteParams).SongNote = undefined;

var contents_arr: [1*1024*1024]u8 = undefined;

fn readFile() ![]const u8 {
    const file = try std.fs.File.openRead("examples/example_song.txt");
    defer file.close();

    var file_size = try file.getEndPos();

    const read_amount = try file.read(contents_arr[0..file_size]);

    if (file_size != read_amount) {
        return error.MyReadFailed;
    }

    return contents_arr[0..read_amount];
}

fn tokenIsWord(token: Token, word: []const u8) bool {
    return switch (token) {
        .Word => |s| std.mem.eql(u8, word, s),
        else => false,
    };
}

fn requireToken(parser: *Parser) !Token {
    return (try parseToken(parser)) orelse error.UnexpectedEof;
}

fn expectNumber(token: Token) !f32 {
    return switch (token) {
        .Number => |n| n,
        else => error.ExpectedNumber,
    };
}

fn makeSongNote(t: f32, freq: f32, note_on: bool) zang.Notes(MyNoteParams).SongNote {
    return zang.Notes(MyNoteParams).SongNote {
        .t = t,
        .params = MyNoteParams {
            .freq = freq,
            .note_on = note_on,
        },
    };
}

fn doParse(parser: *Parser) !void {
    const TrackState = struct {
        last_freq: ?f32,
        num_notes: usize,
    };
    var track_states = [1]TrackState{ TrackState{ .last_freq = null, .num_notes = 0} } ** TOTAL_TRACKS;

    var t: f32 = 0;
    var rate: f32 = 1.0;
    var tempo: f32 = 1.0;

    while (try parseToken(parser)) |token| {
        if (tokenIsWord(token, "start")) {
            t = 0.0;
            var col: usize = 0; while (col < TOTAL_TRACKS) : (col += 1) {
                track_states[col].num_notes = 0;
            }
        } else if (tokenIsWord(token, "rate")) {
            rate = try expectNumber(try requireToken(parser));
        } else if (tokenIsWord(token, "tempo")) {
            tempo = try expectNumber(try requireToken(parser));
        } else {
            switch (token) {
                .Notes => |notes| {
                    for (notes) |note, col| {
                        switch (note) {
                            .Idle => {},
                            .Freq => |freq| {
                                result_arr[col][track_states[col].num_notes] = makeSongNote(t, freq, true);
                                track_states[col].last_freq = freq;
                                track_states[col].num_notes += 1;
                            },
                            .Off => {
                                if (track_states[col].last_freq) |last_freq| {
                                    result_arr[col][track_states[col].num_notes] = makeSongNote(t, last_freq, false);
                                    track_states[col].num_notes += 1;
                                }
                            },
                        }
                    }
                    t += NOTE_DURATION / (rate * tempo);
                },
                else => return error.BadToken,
            }
        }
    }

    var i: usize = 0; while (i < TOTAL_TRACKS) : (i += 1) {
        tracks[i] = result_arr[i][0..track_states[i].num_notes];
    }
}

fn parse() void {
    const contents = readFile() catch {
        std.debug.warn("failed to read file\n");
        return;
    };

    var parser = Parser {
        .contents = contents,
        .index = 0,
        .line_index = 0,
    };

    doParse(&parser) catch {
        std.debug.warn("parse failed on line {}\n", parser.line_index + 1);
    };
}

pub const MainModule = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 2;

    const Voice = struct {
        instrument: Instrument,
        trigger: zang.Trigger(MyNoteParams),
        tracker: zang.Notes(MyNoteParams).NoteTracker,
    };

    voices: [TOTAL_TRACKS]Voice,

    pub fn init() MainModule {
        parse();

        var mod: MainModule = undefined;

        var i: usize = 0;
        while (i < NUM_TRACKS_1) : (i += 1) {
            mod.voices[i] = Voice {
                .instrument = Instrument.init(false),
                .trigger = zang.Trigger(MyNoteParams).init(),
                .tracker = zang.Notes(MyNoteParams).NoteTracker.init(tracks[i]),
            };
        }
        while (i < NUM_TRACKS_1 + NUM_TRACKS_2) : (i += 1) {
            mod.voices[i] = Voice {
                .instrument = Instrument.init(true),
                .trigger = zang.Trigger(MyNoteParams).init(),
                .tracker = zang.Notes(MyNoteParams).NoteTracker.init(tracks[i]),
            };
        }

        return mod;
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        for (self.voices) |*voice| {
            var ctr = voice.trigger.counter(span, voice.tracker.consume(AUDIO_SAMPLE_RATE, span.end - span.start));
            while (voice.trigger.next(&ctr)) |result| {
                voice.instrument.paint(result.span, outputs, temps, result.note_id_changed, Instrument.Params {
                    .sample_rate = AUDIO_SAMPLE_RATE,
                    .freq = result.params.freq,
                    .note_on = result.params.note_on,
                });
            }
        }
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (down and key == c.SDLK_SPACE) {
            parse();

            for (self.voices) |*voice| {
                voice.trigger.reset();
                voice.tracker.reset();
            }
        }
    }
};
