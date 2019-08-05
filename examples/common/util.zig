const std = @import("std");

pub fn readFile(buffer: []u8) ![]const u8 {
    const file = try std.fs.File.openRead("examples/example_song.txt");
    defer file.close();

    var file_size = try file.getEndPos();

    const read_amount = try file.read(buffer[0..file_size]);

    if (file_size != read_amount) {
        return error.MyReadFailed;
    }

    return buffer[0..read_amount];
}
