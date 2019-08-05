const std = @import("std");
const zang = @import("zang");
const f = @import("zang-12tet");
const common = @import("common.zig");
const c = @import("common/c.zig");
const util = @import("common/util.zig");

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

const a4 = 440.0;
const NOTE_DURATION = 0.15;

const Voices = struct {
    voice0: Voice(.PMOsc, 2, 0.5),
    voice1: Voice(.Nice, 8, 1.0),
    voice2: Voice(.WeirdNice, 2, 1.0),
};

// these values are not necessarily the same as the polyphony amount. they're
// just a parsing detail
const COLUMNS_PER_VOICE = [_]usize {
    2,
    8,
    2,
};

comptime {
    std.debug.assert(@typeInfo(Voices).Struct.fields.len == COLUMNS_PER_VOICE.len);
}

const TOTAL_COLUMNS = blk: {
    var sum: usize = 0;
    for (COLUMNS_PER_VOICE) |v| sum += v;
    break :blk sum;
};

const MyNoteParams = struct {
    freq: f32,
    note_on: bool,
};

const NUM_INSTRUMENTS = COLUMNS_PER_VOICE.len;

var all_notes_arr: [NUM_INSTRUMENTS][20000]zang.Notes(MyNoteParams).SongNote = undefined;
var all_notes: [NUM_INSTRUMENTS][]zang.Notes(MyNoteParams).SongNote = undefined;

var contents_arr: [1*1024*1024]u8 = undefined;

fn makeSongNote(t: f32, id: usize, freq: f32, note_on: bool) zang.Notes(MyNoteParams).SongNote {
    return zang.Notes(MyNoteParams).SongNote {
        .t = t,
        .id = id,
        .params = MyNoteParams {
            .freq = freq,
            .note_on = note_on,
        },
    };
}

const Parser = @import("common/songparse1.zig").Parser(TOTAL_COLUMNS);

// NOTE about polyphony: if you retrigger a note at the same frequency, it will
// be played in a separate voice (won't cut off the previous note). polyphony
// doesn't look at note frequency at all, just the on/off events.
fn doParse(parser: *Parser) !void {
    const LastNote = struct {
        freq: f32,
        id: usize,
    };
    var column_last_note = [1]?LastNote{ null } ** TOTAL_COLUMNS;
    var instrument_num_notes = [1]usize{ 0 } ** NUM_INSTRUMENTS;
    var next_id: usize = 1;

    var t: f32 = 0;
    var rate: f32 = 1.0;
    var tempo: f32 = 1.0;

    while (try parser.parseToken()) |token| {
        if (token.isWord("start")) {
            t = 0.0;
            var i: usize = 0; while (i < NUM_INSTRUMENTS) : (i += 1) {
                instrument_num_notes[i] = 0;
            }
        } else if (token.isWord("rate")) {
            rate = try parser.requireNumber();
        } else if (token.isWord("tempo")) {
            tempo = try parser.requireNumber();
        } else {
            switch (token) {
                .Notes => |notes| {
                    const old_instrument_num_notes = instrument_num_notes;

                    for (notes) |note, col| {
                        const instrument_index = blk: {
                            var first_column: usize = 0;
                            for (COLUMNS_PER_VOICE) |num_columns, track_index| {
                                if (col < first_column + num_columns) {
                                    break :blk track_index;
                                }
                                first_column += num_columns;
                            }
                            unreachable;
                        };

                        switch (note) {
                            .Idle => {},
                            .Freq => |freq| {
                                // note-off of previous note in this column (if present)
                                if (column_last_note[col]) |last_note| {
                                    all_notes_arr[instrument_index][instrument_num_notes[instrument_index]] =
                                        makeSongNote(t, last_note.id, last_note.freq, false);
                                    instrument_num_notes[instrument_index] += 1;
                                }
                                // note-on event for the new frequency
                                all_notes_arr[instrument_index][instrument_num_notes[instrument_index]] =
                                    makeSongNote(t, next_id, freq, true);
                                instrument_num_notes[instrument_index] += 1;
                                column_last_note[col] = LastNote {
                                    .id = next_id,
                                    .freq = freq,
                                };
                                next_id += 1;
                            },
                            .Off => {
                                if (column_last_note[col]) |last_note| {
                                    all_notes_arr[instrument_index][instrument_num_notes[instrument_index]] =
                                        makeSongNote(t, last_note.id, last_note.freq, false);
                                    instrument_num_notes[instrument_index] += 1;
                                    column_last_note[col] = null;
                                }
                            },
                        }
                    }

                    t += NOTE_DURATION / (rate * tempo);

                    // sort the events at this time frame by note id. this puts note-offs before note-ons
                    // (not sure if this is really necessary though. if not i might remove the sorting)
                    var i: usize = 0; while (i < NUM_INSTRUMENTS) : (i += 1) {
                        const start = old_instrument_num_notes[i];
                        const end = instrument_num_notes[i];
                        std.sort.sort(zang.Notes(MyNoteParams).SongNote, all_notes_arr[i][start..end], struct {
                            fn compare(a: zang.Notes(MyNoteParams).SongNote, b: zang.Notes(MyNoteParams).SongNote) bool {
                                return a.id < b.id;
                            }
                        }.compare);
                    }
                },
                else => return error.BadToken,
            }
        }
    }

    // now for each of the 3 instruments, we have chronological list of all note on and off events
    // (with a lot of overlapping). the notes need to be identified by their frequency, which kind of sucks.
    // i should probably change the parser above to assign them unique IDs.
    var i: usize = 0; while (i < NUM_INSTRUMENTS) : (i += 1) {
        all_notes[i] = all_notes_arr[i][0..instrument_num_notes[i]];
    }

    // i = 0; while (i < NUM_INSTRUMENTS) : (i += 1) {
    //     if (i == 1) {
    //         std.debug.warn("instrument {}:\n", i);
    //         for (all_notes[i]) |note| {
    //             std.debug.warn("t={}  id={}  freq={}  note_on={}\n", note.t, note.id, note.params.freq, note.params.note_on);
    //         }
    //     }
    // }
}

fn parse() void {
    const contents = util.readFile(contents_arr[0..]) catch {
        std.debug.warn("failed to read file\n");
        return;
    };

    var parser = Parser {
        .a4 = a4,
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
    WeirdNice,
    FltSaw,
    PMOsc,
};

fn Voice(comptime si: SupportedInstrument, comptime polyphony: usize, comptime freq_mul: f32) type {
    const modules = @import("modules.zig");

    return struct {
        const Instrument = switch (si) {
            .HardSquare => modules.HardSquareInstrument,
            .Organ,
            .WeirdOrgan => modules.SquareWithEnvelope,
            .Nice,
            .WeirdNice => modules.NiceInstrument,
            .FltSaw => modules.FilteredSawtoothInstrument,
            .PMOsc => modules.PMOscInstrument,
        };

        const SubVoice = struct {
            module: Instrument,
            trigger: zang.Trigger(MyNoteParams),
        };

        tracker: zang.Notes(MyNoteParams).NoteTracker,
        dispatcher: zang.Notes(MyNoteParams).PolyphonyDispatcher(polyphony),

        sub_voices: [polyphony]SubVoice,

        fn init(track_index: usize) @This() {
            var self = @This() {
                .tracker = zang.Notes(MyNoteParams).NoteTracker.init(all_notes[track_index]),
                .dispatcher = zang.Notes(MyNoteParams).PolyphonyDispatcher(polyphony).init(),
                .sub_voices = undefined,
            };
            var i: usize = 0; while (i < polyphony) : (i += 1) {
                self.sub_voices[i] = SubVoice {
                    .module = switch (si) {
                        .HardSquare => modules.HardSquareInstrument.init(),
                        .Organ => modules.SquareWithEnvelope.init(false),
                        .WeirdOrgan => modules.SquareWithEnvelope.init(true),
                        .Nice => modules.NiceInstrument.init(0.25),
                        .WeirdNice => modules.NiceInstrument.init(0.1),
                        .FltSaw => modules.FilteredSawtoothInstrument.init(),
                        .PMOsc => modules.PMOscInstrument.init(0.4),
                    },
                    .trigger = zang.Trigger(MyNoteParams).init(),
                };
            }
            return self;
        }

        fn makeParams(voice: *const @This(), sample_rate: f32, source_params: MyNoteParams) Instrument.Params {
            return switch (si) {
                .HardSquare,
                .Organ,
                .WeirdOrgan,
                .Nice,
                .WeirdNice,
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

pub const MainModule = struct {
    pub const num_outputs = 1;
    pub const num_temps = blk: {
        comptime var n: usize = 0;
        inline for (@typeInfo(Voices).Struct.fields) |field| {
            n = std.math.max(n, @field(field.field_type, "Instrument").num_temps);
        }
        break :blk n;
    };

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

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32) void {
        inline for (@typeInfo(Voices).Struct.fields) |field| {
            const Instrument = @field(field.field_type, "Instrument");
            const voice = &@field(self.voices, field.name);

            const iap = voice.tracker.consume(AUDIO_SAMPLE_RATE, span.end - span.start);

            const poly_iap = voice.dispatcher.dispatch(iap);

            for (voice.sub_voices) |*sub_voice, i| {
                var ctr = sub_voice.trigger.counter(span, poly_iap[i]);

                while (sub_voice.trigger.next(&ctr)) |result| {
                    const params = voice.makeParams(AUDIO_SAMPLE_RATE, result.params);
                    var inner_temps: [Instrument.num_temps][]f32 = undefined;
                    var j: usize = 0; while (j < Instrument.num_temps) : (j += 1) {
                        inner_temps[j] = temps[j];
                    }
                    sub_voice.module.paint(result.span, outputs, inner_temps, result.note_id_changed, params);
                }
            }
        }
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (down and key == c.SDLK_SPACE) {
            inline for (@typeInfo(Voices).Struct.fields) |field| {
                const voice = &@field(self.voices, field.name);

                voice.tracker.reset();
                for (voice.sub_voices) |*sub_voice| {
                    sub_voice.trigger.reset();
                }
            }
        }
    }
};
