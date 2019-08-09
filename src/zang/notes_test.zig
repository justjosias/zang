const std = @import("std");

const Impulse = @import("notes.zig").Impulse;
const Notes = @import("notes.zig").Notes;

const MyNoteParams = struct {
    note_on: bool,
};

test "PolyphonyDispatcher: 5 note-ons with 3 slots" {
    const iap = Notes(MyNoteParams).ImpulsesAndParamses {
        .impulses = [_]Impulse {
            Impulse { .frame = 100, .note_id = 1, .event_id = 1 },
            Impulse { .frame = 200, .note_id = 2, .event_id = 2 },
            Impulse { .frame = 300, .note_id = 3, .event_id = 3 },
            Impulse { .frame = 400, .note_id = 4, .event_id = 4 },
            Impulse { .frame = 500, .note_id = 5, .event_id = 5 },
        },
        .paramses = [_]MyNoteParams {
            MyNoteParams { .note_on = true },
            MyNoteParams { .note_on = true },
            MyNoteParams { .note_on = true },
            MyNoteParams { .note_on = true },
            MyNoteParams { .note_on = true },
        },
    };

    var pd = Notes(MyNoteParams).PolyphonyDispatcher(3).init();

    const result = pd.dispatch(iap);

    std.testing.expectEqual(usize(1), result[0].impulses[0].note_id);
    std.testing.expectEqual(usize(2), result[1].impulses[0].note_id);
    std.testing.expectEqual(usize(3), result[2].impulses[0].note_id);
    std.testing.expectEqual(usize(4), result[0].impulses[1].note_id);
    std.testing.expectEqual(usize(5), result[1].impulses[1].note_id);

    std.testing.expectEqual(usize(2), result[0].impulses.len);
    std.testing.expectEqual(usize(2), result[1].impulses.len);
    std.testing.expectEqual(usize(1), result[2].impulses.len);
}

test "PolyphonyDispatcher: single note on and off" {
    const iap = Notes(MyNoteParams).ImpulsesAndParamses {
        .impulses = [_]Impulse {
            Impulse { .frame = 100, .note_id = 1, .event_id = 1 },
            Impulse { .frame = 200, .note_id = 1, .event_id = 2 },
            Impulse { .frame = 300, .note_id = 2, .event_id = 3 },
            Impulse { .frame = 400, .note_id = 2, .event_id = 4 },
            Impulse { .frame = 500, .note_id = 3, .event_id = 5 },
        },
        .paramses = [_]MyNoteParams {
            MyNoteParams { .note_on = true },
            MyNoteParams { .note_on = false },
            MyNoteParams { .note_on = true },
            MyNoteParams { .note_on = false },
            MyNoteParams { .note_on = true },
        },
    };

    var pd = Notes(MyNoteParams).PolyphonyDispatcher(3).init();

    const result = pd.dispatch(iap);

    std.testing.expectEqual(usize(1), result[0].impulses[0].note_id);
    std.testing.expectEqual(usize(1), result[0].impulses[1].note_id);
    std.testing.expectEqual(usize(2), result[1].impulses[0].note_id);
    std.testing.expectEqual(usize(2), result[1].impulses[1].note_id);
    std.testing.expectEqual(usize(3), result[2].impulses[0].note_id);

    std.testing.expectEqual(usize(2), result[0].impulses.len);
    std.testing.expectEqual(usize(2), result[1].impulses.len);
    std.testing.expectEqual(usize(1), result[2].impulses.len);
}

test "PolyphonyDispatcher: reuse least recently released slot" {
    const iap = Notes(MyNoteParams).ImpulsesAndParamses {
        .impulses = [_]Impulse {
            Impulse { .frame = 100, .note_id = 1, .event_id = 1 },
            Impulse { .frame = 200, .note_id = 2, .event_id = 2 },
            Impulse { .frame = 300, .note_id = 3, .event_id = 3 },

            Impulse { .frame = 400, .note_id = 3, .event_id = 4 },
            Impulse { .frame = 500, .note_id = 2, .event_id = 5 },
            Impulse { .frame = 600, .note_id = 1, .event_id = 6 },

            Impulse { .frame = 700, .note_id = 4, .event_id = 7 },
        },
        .paramses = [_]MyNoteParams {
            MyNoteParams { .note_on = true },
            MyNoteParams { .note_on = true },
            MyNoteParams { .note_on = true },
            MyNoteParams { .note_on = false },
            MyNoteParams { .note_on = false },
            MyNoteParams { .note_on = false },
            MyNoteParams { .note_on = true },
        },
    };

    var pd = Notes(MyNoteParams).PolyphonyDispatcher(3).init();

    const result = pd.dispatch(iap);

    std.testing.expectEqual(usize(1), result[0].impulses[0].note_id);
    std.testing.expectEqual(usize(2), result[1].impulses[0].note_id);
    std.testing.expectEqual(usize(3), result[2].impulses[0].note_id);

    std.testing.expectEqual(usize(3), result[2].impulses[1].note_id);
    std.testing.expectEqual(usize(2), result[1].impulses[1].note_id);
    std.testing.expectEqual(usize(1), result[0].impulses[1].note_id);

    // slot 0 is the least recent note-on.
    // slot 2 is the least recent note-off. this is what we want
    std.testing.expectEqual(usize(4), result[2].impulses[2].note_id);

    std.testing.expectEqual(usize(2), result[0].impulses.len);
    std.testing.expectEqual(usize(2), result[1].impulses.len);
    std.testing.expectEqual(usize(3), result[2].impulses.len);
}
