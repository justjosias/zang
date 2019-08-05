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

// return a new array copied from the first part of the source array.
// like `arr[0..new_size]`, but working with arrays of comptime known length
// (and actually copying data)
pub fn subarray(arr: var, comptime new_size: usize) [new_size]@typeInfo(@typeOf(arr)).Array.child {
    std.debug.assert(new_size <= @typeInfo(@typeOf(arr)).Array.len);
    var result: [new_size]@typeInfo(@typeOf(arr)).Array.child = undefined;
    var i: usize = 0; while (i < new_size) : (i += 1) {
        result[i] = arr[i];
    }
    return result;
}
