const std = @import("std");
const zang = @import("zang");
const f = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/c.zig");

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
const TOTAL_TRACKS = @typeInfo(Voices).Struct.fields.len;

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

    fn parseNote(parser: *Parser) ?f32 {
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

        return A4 * std.math.pow(f32, 2.0, @intToFloat(f32, offset + semitone) / 12.0);
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

            var notes = [1]Note { Note { .Idle = {} } } ** TOTAL_TRACKS;

            var col: usize = 0; while (true) : (col += 1) {
                if (parseNote(parser)) |freq| {
                    notes[col] = Note { .Freq = freq };
                } else if (parser.index + 3 <= parser.contents.len and std.mem.eql(u8, parser.contents[parser.index .. parser.index + 3], "off")) {
                    notes[col] = Note { .Off = {} };
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

    fn requireToken(parser: *Parser) !Token {
        return (try parser.parseToken()) orelse error.UnexpectedEof;
    }

    fn requireNumber(parser: *Parser) !f32 {
        return switch (try parser.requireToken()) {
            .Number => |n| n,
            else => error.ExpectedNumber,
        };
    }
};

const MyNoteParams = struct {
    freq: f32,
    note_on: bool,
};

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

fn isWord(token: Token, word: []const u8) bool {
    return switch (token) {
        .Word => |s| std.mem.eql(u8, word, s),
        else => false,
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

    while (try parser.parseToken()) |token| {
        if (isWord(token, "start")) {
            t = 0.0;
            var col: usize = 0; while (col < TOTAL_TRACKS) : (col += 1) {
                track_states[col].num_notes = 0;
            }
        } else if (isWord(token, "rate")) {
            rate = try parser.requireNumber();
        } else if (isWord(token, "tempo")) {
            tempo = try parser.requireNumber();
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

const SupportedInstrument = enum {
    HardSquare,
    Organ,
    WeirdOrgan,
    Nice,
    FltSaw,
    PMOsc,
};

fn Voice(comptime si: SupportedInstrument, comptime freq_mul: f32) type {
    const modules = @import("modules.zig");

    return struct {
        const Instrument = switch (si) {
            .HardSquare => modules.HardSquareInstrument,
            .Organ => modules.SquareWithEnvelope,
            .WeirdOrgan => modules.SquareWithEnvelope,
            .Nice => modules.NiceInstrument,
            .FltSaw => modules.FilteredSawtoothInstrument,
            .PMOsc => modules.PMOscInstrument,
        };

        instrument: Instrument,
        trigger: zang.Trigger(MyNoteParams),
        tracker: zang.Notes(MyNoteParams).NoteTracker,

        fn init(track_index: usize) @This() {
            return @This() {
                .instrument = switch (si) {
                    .HardSquare => modules.HardSquareInstrument.init(),
                    .Organ => modules.SquareWithEnvelope.init(false),
                    .WeirdOrgan => modules.SquareWithEnvelope.init(true),
                    .Nice => modules.NiceInstrument.init(),
                    .FltSaw => modules.FilteredSawtoothInstrument.init(),
                    .PMOsc => modules.PMOscInstrument.init(0.15),
                },
                .trigger = zang.Trigger(MyNoteParams).init(),
                .tracker = zang.Notes(MyNoteParams).NoteTracker.init(tracks[track_index]),
            };
        }

        fn makeParams(voice: *const @This(), sample_rate: f32, source_params: MyNoteParams) Instrument.Params {
            return switch (si) {
                .HardSquare,
                .Organ,
                .WeirdOrgan,
                .Nice,
                .FltSaw,
                .PMOsc => Instrument.Params {
                    .sample_rate = sample_rate,
                    .freq = source_params.freq * freq_mul,
                    .note_on = source_params.note_on,
                },
            };
        }
    };
}

const InstrumentOrgan = .Organ;
const InstrumentPedal = .PMOsc;
const InstrumentWeirdOrgan = .WeirdOrgan;
const Voices = struct {
    pedal0: Voice(InstrumentPedal, 0.5),
    pedal1: Voice(InstrumentPedal, 0.5),
    voice0: Voice(InstrumentOrgan, 1.0),
    voice1: Voice(InstrumentOrgan, 1.0),
    voice2: Voice(InstrumentOrgan, 1.0),
    voice3: Voice(InstrumentOrgan, 1.0),
    voice4: Voice(InstrumentOrgan, 1.0),
    voice5: Voice(InstrumentOrgan, 1.0),
    voice6: Voice(InstrumentOrgan, 1.0),
    voice7: Voice(InstrumentOrgan, 1.0),
    voice8: Voice(InstrumentOrgan, 1.0),
    voice9: Voice(InstrumentWeirdOrgan, 1.0),
    voice10: Voice(InstrumentWeirdOrgan, 1.0),
};

fn getNumTemps() usize {
    comptime var num_temps: usize = 0;

    inline for (@typeInfo(Voices).Struct.fields) |field| {
        const n = @field(field.field_type, "Instrument").NumTemps;

        if (n > num_temps) {
            num_temps = n;
        }
    }

    return num_temps;
}

pub const MainModule = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = getNumTemps();

    voices: Voices,

    pub fn init() MainModule {
        parse();

        var mod = MainModule {
            .voices = undefined,
        };

        inline for (@typeInfo(Voices).Struct.fields) |field, track_index| {
            @field(mod.voices, field.name) = field.field_type.init(track_index);
        }

        return mod;
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [NumOutputs][]f32, temps: [NumTemps][]f32) void {
        inline for (@typeInfo(Voices).Struct.fields) |field| {
            const Instrument = @field(field.field_type, "Instrument");
            const voice = &@field(self.voices, field.name);

            var ctr = voice.trigger.counter(span, voice.tracker.consume(AUDIO_SAMPLE_RATE, span.end - span.start));
            while (voice.trigger.next(&ctr)) |result| {
                const params = voice.makeParams(AUDIO_SAMPLE_RATE, result.params);
                var inner_temps: [Instrument.NumTemps][]f32 = undefined;
                var i: usize = 0; while (i < Instrument.NumTemps) : (i += 1) {
                    inner_temps[i] = temps[i];
                }
                voice.instrument.paint(result.span, outputs, inner_temps, result.note_id_changed, params);
            }
        }
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (down and key == c.SDLK_SPACE) {
            inline for (@typeInfo(Voices).Struct.fields) |field| {
                const voice = &@field(self.voices, field.name);

                voice.trigger.reset();
                voice.tracker.reset();
            }
        }
    }
};
