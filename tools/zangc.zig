const std = @import("std");
const zangscript = @import("zangscript");

const builtin_packages = [_]zangscript.BuiltinPackage{
    zangscript.zang_builtin_package,
};

fn usage(out: *std.fs.File.OutStream, program_name: []const u8) void {
    out.print("Usage: {} [options...] <file>\n\n", .{program_name}) catch return;
    out.writeAll(
        \\Compile the zangscript source at <file> into Zig code.
        \\
        \\      --dump-parse <file>    Dump result of parse stage to file
        \\      --dump-codegen <file>  Dump result of codegen stage to file
        \\  -o, --output <file>        Write Zig code to file instead of stdout
        \\      --color <when>         Colorize compile errors; 'when' can be 'auto'
        \\                               (default if omitted), 'always', or 'never'
        \\
    ) catch {};
}

const Options = struct {
    const Color = enum { auto, always, never };

    arena: std.heap.ArenaAllocator,
    script_filename: []const u8,
    output_filename: ?[]const u8,
    dump_parse_filename: ?[]const u8,
    dump_codegen_filename: ?[]const u8,
    color: Color,

    fn deinit(self: Options) void {
        self.arena.deinit();
    }
};

fn parseOptions(stderr: *std.fs.File.OutStream, allocator: *std.mem.Allocator) !Options {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var script_filename: ?[]const u8 = null;
    var output_filename: ?[]const u8 = null;
    var dump_parse_filename: ?[]const u8 = null;
    var dump_codegen_filename: ?[]const u8 = null;
    var color: Options.Color = .auto;

    var args = std.process.args();
    const program = try args.next(&arena.allocator) orelse "zangc";
    while (true) {
        const arg = try args.next(&arena.allocator) orelse break;
        if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            const value = try args.next(&arena.allocator) orelse {
                stderr.print("{}: missing value for '{}'\n", .{ program, arg }) catch {};
                return error.Failed;
            };
            output_filename = value;
        } else if (std.mem.eql(u8, arg, "--dump-parse")) {
            const value = try args.next(&arena.allocator) orelse {
                stderr.print("{}: missing value for '{}'\n", .{ program, arg }) catch {};
                return error.Failed;
            };
            dump_parse_filename = value;
        } else if (std.mem.eql(u8, arg, "--dump-codegen")) {
            const value = try args.next(&arena.allocator) orelse {
                stderr.print("{}: missing value for '{}'\n", .{ program, arg }) catch {};
                return error.Failed;
            };
            dump_codegen_filename = value;
        } else if (std.mem.eql(u8, arg, "--color")) {
            const value = try args.next(&arena.allocator) orelse {
                stderr.print("{}: missing value for '{}'\n", .{ program, arg }) catch {};
                return error.Failed;
            };
            if (std.mem.eql(u8, value, "auto")) {
                color = .auto;
            } else if (std.mem.eql(u8, value, "always")) {
                color = .always;
            } else if (std.mem.eql(u8, value, "never")) {
                color = .never;
            } else {
                stderr.print("{}: invalid value '{}' for '{}'; must be one of 'auto', 'always', 'never'\n", .{ program, value, arg }) catch {};
                return error.Failed;
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            stderr.print("{}: unrecognized option '{}'\n", .{ program, arg }) catch {};
            return error.Failed;
        } else {
            script_filename = arg;
        }
    }

    return Options{
        .arena = arena,
        .script_filename = script_filename orelse {
            usage(stderr, program);
            return error.Failed;
        },
        .output_filename = output_filename,
        .dump_parse_filename = dump_parse_filename,
        .dump_codegen_filename = dump_codegen_filename,
        .color = color,
    };
}

pub fn main() u8 {
    var leak_count_allocator = std.testing.LeakCountAllocator.init(std.heap.page_allocator);
    defer leak_count_allocator.validate() catch {};

    var allocator = &leak_count_allocator.allocator;

    var stderr = std.debug.getStderrStream();

    const options = parseOptions(stderr, allocator) catch |err| {
        // `error.Failed` means an error was already printed to stderr
        if (err != error.Failed) stderr.print("error while parsing args: {}\n", .{err}) catch {};
        return 1;
    };
    defer options.deinit();

    const contents = std.fs.cwd().readFileAlloc(allocator, options.script_filename, 16 * 1024 * 1024) catch |err| {
        stderr.print("failed to load {}: {}\n", .{ options.script_filename, err }) catch {};
        return 1;
    };
    defer allocator.free(contents);

    var files_to_close: [8]std.fs.File = undefined;
    var num_files_to_close: usize = 0;
    defer for (files_to_close[0..num_files_to_close]) |file| file.close();

    const errors_file = std.io.getStdErr();
    const errors_color = switch (options.color) {
        .auto => errors_file.isTty(),
        .always => true,
        .never => false,
    };
    var errors_stream: std.io.StreamSource = .{ .file = errors_file };
    var dump_parse_stream: std.io.StreamSource = undefined;
    if (options.dump_parse_filename) |filename| {
        var file = std.fs.cwd().createFile(filename, .{}) catch |err| {
            stderr.print("failed to open {} for writing: {}\n", .{ filename, err }) catch {};
            return 1;
        };
        files_to_close[num_files_to_close] = file;
        num_files_to_close += 1;
        dump_parse_stream = .{ .file = file };
    }
    var dump_codegen_stream: std.io.StreamSource = undefined;
    if (options.dump_codegen_filename) |filename| {
        var file = std.fs.cwd().createFile(filename, .{}) catch |err| {
            stderr.print("failed to open {} for writing: {}\n", .{ filename, err }) catch {};
            return 1;
        };
        files_to_close[num_files_to_close] = file;
        num_files_to_close += 1;
        dump_codegen_stream = .{ .file = file };
    }

    var script = zangscript.compile(.{
        .source = .{
            .filename = options.script_filename,
            .contents = contents,
        },
        .errors_out = errors_stream.outStream(),
        .errors_color = errors_color,
        .dump_parse_out = if (options.dump_parse_filename != null) dump_parse_stream.outStream() else null,
        .dump_codegen_out = if (options.dump_codegen_filename != null) dump_codegen_stream.outStream() else null,
    }, &builtin_packages, allocator) catch |err| {
        // `error.Failed` means an error was already printed to stderr
        if (err != error.Failed) stderr.print("{}\n", .{err}) catch {};
        return 1;
    };
    defer script.deinit();

    var out_file: std.fs.File = undefined;
    if (options.output_filename) |out_filename| {
        var file = std.fs.cwd().createFile(out_filename, .{}) catch |err| {
            stderr.print("failed to open {} for writing: {}\n", .{ out_filename, err }) catch {};
            return 1;
        };
        files_to_close[num_files_to_close] = file;
        num_files_to_close += 1;
        out_file = file;
    } else {
        out_file = std.io.getStdOut();
    }

    var out_ss: std.io.StreamSource = .{ .file = out_file };
    zangscript.generateZig(out_ss.outStream(), &builtin_packages, script) catch |err| {
        stderr.print("generateZig failed: {}\n", .{err}) catch {};
        return 1;
    };

    return 0;
}
