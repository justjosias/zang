pub const Impulse = struct {
    frame: i32, // frames (e.g. 44100 for one second in)
    note: ?NoteSpanNote, // null if it's a silent gap
    next: ?*const Impulse,
};

pub const NoteSpanNote = struct {
    id: usize,
    freq: f32,
};
