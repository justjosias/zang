const std = @import("std");

pub const Source = struct {
    filename: []const u8,
    contents: []const u8,

    pub fn getString(self: Source, source_range: SourceRange) []const u8 {
        return self.contents[source_range.loc0.index..source_range.loc1.index];
    }
};

pub const SourceLocation = struct {
    // which line in the source file (starts at 0)
    line: usize,
    // byte offset into source file.
    // the column can be found by searching backward for a newline
    index: usize,
};

pub const SourceRange = struct {
    loc0: SourceLocation,
    loc1: SourceLocation,
};

pub const Context = struct {
    source: Source,
    errors_out: std.io.StreamSource.OutStream,
    errors_color: bool,
};
