const std = @import("std");
const zang = @import("zang");
const f = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/c.zig");
const Instrument = @import("modules.zig").PMOscInstrument;

pub const AUDIO_FORMAT = zang.AudioFormat.S16LSB;
pub const AUDIO_SAMPLE_RATE = 48000;
pub const AUDIO_BUFFER_SIZE = 4096;

pub const DESCRIPTION =
    c\\example_song
    c\\
    c\\Plays a canned melody (the first few bars of Bach's
    c\\Toccata in D Minor).
    c\\
    c\\This example is not interactive.
;

const A4 = 440.0;

const MyNoteParams = struct { freq: f32, note_on: bool };

const Parser = struct {
    contents: []const u8,
    index: usize,
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

var result_arr: [NUM_TRACKS][9999]zang.Notes(MyNoteParams).SongNote = undefined;

fn parse() [NUM_TRACKS][]zang.Notes(MyNoteParams).SongNote {
    var parser = Parser {
        .contents = @embedFile("example_song.txt"),
        .index = 0,
    };

    const TrackState = struct {
        last_freq: ?f32,
        num_notes: usize,
    };
    var track_states = [1]TrackState{ TrackState{ .last_freq = null, .num_notes = 0} } ** NUM_TRACKS;

    var offset: usize = 0;

    while (true) {
        var col: usize = 0; while (true) : (col += 1) {
            if (parseNote(&parser)) |note| {
                result_arr[col][track_states[col].num_notes] = zang.Notes(MyNoteParams).SongNote {
                    .t = @intToFloat(f32, offset) * NOTE_DURATION,
                    .params = note,
                };
                track_states[col].last_freq = note.freq;
                track_states[col].num_notes += 1;
            } else if (parser.index + 3 <= parser.contents.len and std.mem.eql(u8, parser.contents[parser.index .. parser.index + 3], "off")) {
                if (track_states[col].last_freq) |last_freq| {
                    result_arr[col][track_states[col].num_notes] = zang.Notes(MyNoteParams).SongNote {
                        .t = @intToFloat(f32, offset) * NOTE_DURATION,
                        .params = MyNoteParams {
                            .freq = last_freq,
                            .note_on = false,
                        },
                    };
                    track_states[col].num_notes += 1;
                }
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
        if (parser.index == parser.contents.len) {
            break;
        }
        if (parser.contents[parser.index] == '\n') {
            parser.index += 1;
            offset += 1;
        } else {
            std.debug.warn("fail\n");
            break;
        }
    }

    var result: [NUM_TRACKS][]zang.Notes(MyNoteParams).SongNote = undefined;
    var i: usize = 0; while (i < NUM_TRACKS) : (i += 1) {
        result[i] = result_arr[i][0..track_states[i].num_notes];
    }
    return result;
}

const NUM_TRACKS = 8;
const NOTE_DURATION = 0.08;

// FIXME - there's a crash in the zig compiler preventing me from calling this in the global scope?
// https://github.com/ziglang/zig/issues/2889
// const tracks = parse();
var tracks: [NUM_TRACKS][]zang.Notes(MyNoteParams).SongNote = undefined;

pub const MainModule = struct {
    pub const NumOutputs = 1;
    pub const NumTemps = 4;

    const Voice = struct {
        instrument: Instrument,
        trigger: zang.Trigger(MyNoteParams),
        tracker: zang.Notes(MyNoteParams).NoteTracker,
    };

    voices: [NUM_TRACKS]Voice,

    pub fn init() MainModule {
        tracks = parse(); // TODO - remove (see above)

        var mod: MainModule = undefined;

        var i: usize = 0; while (i < NUM_TRACKS) : (i += 1) {
            mod.voices[i] = Voice {
                .instrument = Instrument.init(0.15),
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
};
