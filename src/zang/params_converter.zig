const std = @import("std");
const Notes = @import("notes.zig").Notes;

pub fn ParamsConverter(comptime SourceParamsType: type, comptime DestParamsType: type) type {
    return struct {
        const SourceNotes = Notes(SourceParamsType);
        const DestNotes = Notes(DestParamsType);

        pub const Pair = struct {
            source: SourceParamsType,
            dest: DestParamsType,
        };

        // this is annoying.
        // idea: for impulses, store params in an external, parallel array, and reference them by index?
        pairs_array: [33]Pair,
        num_pairs: usize,
        impulses_array: [33]DestNotes.Impulse,
        source_impulses: ?*const SourceNotes.Impulse,

        pub fn init() @This() {
            var self: @This() = undefined;
            return self;
        }

        // return a list of pairs which the caller can use to set each
        // destination note params, with the source note params available to
        // use as a base (if desired).
        pub fn getPairs(self: *@This(), impulses: ?*const SourceNotes.Impulse) []Pair {
            var maybe_impulse = impulses;
            var i: usize = 0;
            while (maybe_impulse) |impulse| : ({ maybe_impulse = impulse.next; i += 1; }) {
                self.pairs_array[i].source = impulse.note.params;
            }
            self.source_impulses = impulses;
            self.num_pairs = i;
            return self.pairs_array[0..i];
        }

        // call this after getPairs (and after manually setting all dest note
        // params)
        pub fn getImpulses(self: *@This()) ?*const DestNotes.Impulse {
            var maybe_impulse = self.source_impulses;
            var i: usize = 0;
            while (maybe_impulse) |impulse| : ({ maybe_impulse = impulse.next; i += 1; }) {
                self.impulses_array[i] = DestNotes.Impulse {
                    .frame = impulse.frame,
                    .note = DestNotes.NoteSpanNote {
                        .id = impulse.note.id,
                        .params = self.pairs_array[i].dest,
                    },
                    .next = null,
                };
            }
            const count = i;
            if (count > 0) {
                i = 0;
                while (i < count - 1) : (i += 1) {
                    self.impulses_array[i].next = &self.impulses_array[i + 1];
                }
                return &self.impulses_array[0];
            } else {
                return null;
            }
        }

        // perform an automatic conversion, using a "structural" method:
        // try to fill each field in the dest params with a field with the same
        // name in the source params
        pub fn autoStructural(self: *@This(), impulses: ?*const SourceNotes.Impulse) ?*const DestNotes.Impulse {
            for (self.getPairs(impulses)) |*pair| {
                inline for (@typeInfo(DestParamsType).Struct.fields) |field| {
                    @field(pair.dest, field.name) = @field(pair.source, field.name);
                }
            }
            return self.getImpulses();
        }
    };
}
