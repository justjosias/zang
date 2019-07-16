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
    c\\Plays a canned melody (Bach's Toccata and Fugue in D
    c\\Minor).
    c\\
    c\\This example is not interactive.
;

const A4 = 220.0;
const NOTE_DURATION = 0.15;
const NUM_TRACKS = 9;

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
var tracks: [NUM_TRACKS][]zang.Notes(MyNoteParams).SongNote = undefined;

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

fn parse() void {
    const contents = readFile() catch {
        std.debug.warn("failed to read song file\n");
        return;
    };

    var parser = Parser {
        .contents = contents,
        .index = 0,
    };

    const TrackState = struct {
        last_freq: ?f32,
        num_notes: usize,
    };
    var track_states = [1]TrackState{ TrackState{ .last_freq = null, .num_notes = 0} } ** NUM_TRACKS;

    var t: f32 = 0;
    var rate: f32 = 1.0;
    var tempo: f32 = 1.0;

    while (true) {
        var col: usize = 0; while (true) : (col += 1) {
            if (parseNote(&parser)) |note| {
                result_arr[col][track_states[col].num_notes] = zang.Notes(MyNoteParams).SongNote {
                    .t = t,
                    .params = note,
                };
                track_states[col].last_freq = note.freq;
                track_states[col].num_notes += 1;
            } else if (parser.index + 3 <= parser.contents.len and std.mem.eql(u8, parser.contents[parser.index .. parser.index + 3], "off")) {
                if (track_states[col].last_freq) |last_freq| {
                    result_arr[col][track_states[col].num_notes] = zang.Notes(MyNoteParams).SongNote {
                        .t = t,
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
            t += NOTE_DURATION / (rate * tempo);
        } else if (parser.index + 6 <= parser.contents.len and std.mem.eql(u8, parser.contents[parser.index .. parser.index + 6], "start\n")) {
            parser.index += 6;
            t = 0.0;
            col = 0; while (col < NUM_TRACKS) : (col += 1) {
                track_states[col].num_notes = 0;
            }
        } else if (parser.index + 5 <= parser.contents.len and std.mem.eql(u8, parser.contents[parser.index .. parser.index + 5], "rate ")) {
            parser.index += 5;
            var endpos: usize = parser.index; while (endpos < parser.contents.len and parser.contents[endpos] != '\n') : (endpos += 1) {}
            const slice = parser.contents[parser.index .. endpos];
            const value = std.fmt.parseFloat(f32, slice) catch {
                std.debug.warn("parseFloat fail\n");
                break;
            };
            parser.index = endpos;
            if (parser.index < parser.contents.len) {
                parser.index += 1; // skip newline
            }
            rate = value;
        } else if (parser.index + 6 <= parser.contents.len and std.mem.eql(u8, parser.contents[parser.index .. parser.index + 6], "tempo ")) {
            parser.index += 6;
            var endpos: usize = parser.index; while (endpos < parser.contents.len and parser.contents[endpos] != '\n') : (endpos += 1) {}
            const slice = parser.contents[parser.index .. endpos];
            const value = std.fmt.parseFloat(f32, slice) catch {
                std.debug.warn("parseFloat fail\n");
                break;
            };
            parser.index = endpos;
            if (parser.index < parser.contents.len) {
                parser.index += 1; // skip newline
            }
            tempo = value;
        } else if (parser.index + 1 <= parser.contents.len and std.mem.eql(u8, parser.contents[parser.index .. parser.index + 1], "#")) {
            // comment
            parser.index += 1;
            var endpos: usize = parser.index; while (endpos < parser.contents.len and parser.contents[endpos] != '\n') : (endpos += 1) {}
            parser.index = endpos;
            if (parser.index < parser.contents.len) {
                parser.index += 1; // skip newline
            }
        } else {
            std.debug.warn("fail\n");
            break;
        }
    }

    var i: usize = 0; while (i < NUM_TRACKS) : (i += 1) {
        tracks[i] = result_arr[i][0..track_states[i].num_notes];
    }
}

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
        parse();

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

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (down and key == c.SDLK_SPACE) {
            parse();

            for (self.voices) |*voice| {
                voice.trigger.reset();
                voice.tracker.reset();
            }

            std.debug.warn("reloaded\n");
        }
    }
};
