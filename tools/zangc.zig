const std = @import("std");
const zangscript = @import("zangscript");

const builtin_packages = [_]zangscript.BuiltinPackage{
    zangscript.zang_builtin_package,
};

fn usage(out: *std.fs.File.OutStream, program_name: []const u8) !void {
    try out.print("Usage: {} [options...] <file>\n\n", .{program_name});
    try out.writeAll(
        \\Compile the zangscript source at <file> into Zig code.
        \\
        \\      --dump-parse <file>    Dump result of parse stage to file
        \\      --dump-codegen <file>  Dump result of codegen stage to file
        \\      --help                 Print this help text
        \\  -o, --output <file>        Write Zig code to file instead of stdout
        \\      --color <when>         Colorize compile errors; 'when' can be 'auto'
        \\                               (default if omitted), 'always', or 'never'
        \\
    );
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

const OptionsParser = struct {
    arena_allocator: *std.mem.Allocator,
    stderr: *std.fs.File.OutStream,
    args: std.process.ArgIterator,
    program: []const u8,

    fn init(arena_allocator: *std.mem.Allocator, stderr: *std.fs.File.OutStream) !OptionsParser {
        var args = std.process.args();
        const program = try args.next(arena_allocator) orelse "zangc";
        return OptionsParser{
            .arena_allocator = arena_allocator,
            .stderr = stderr,
            .args = args,
            .program = program,
        };
    }

    fn next(self: *OptionsParser) !?[]const u8 {
        return try self.args.next(self.arena_allocator) orelse return null;
    }

    fn argWithValue(self: *OptionsParser, arg: []const u8, comptime variants: []const []const u8) !?[]const u8 {
        for (variants) |variant| if (std.mem.eql(u8, arg, variant)) break else return null;
        const value = try self.args.next(self.arena_allocator) orelse return self.argError("missing value for '{}'\n", .{arg});
        return value;
    }

    fn argError(self: OptionsParser, comptime fmt: []const u8, args: var) error{ArgError} {
        self.stderr.print("{}: ", .{self.program}) catch {};
        self.stderr.print(fmt, args) catch {};
        self.stderr.print("Try '{} --help' for more information.\n", .{self.program}) catch {};
        return error.ArgError;
    }
};

fn parseOptions(stderr: *std.fs.File.OutStream, allocator: *std.mem.Allocator) !?Options {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var help = false;
    var script_filename: ?[]const u8 = null;
    var output_filename: ?[]const u8 = null;
    var dump_parse_filename: ?[]const u8 = null;
    var dump_codegen_filename: ?[]const u8 = null;
    var color: Options.Color = .auto;

    var parser = try OptionsParser.init(&arena.allocator, stderr);
    while (try parser.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            help = true;
        } else if (try parser.argWithValue(arg, &[_][]const u8{ "--output", "-o" })) |value| {
            output_filename = value;
        } else if (try parser.argWithValue(arg, &[_][]const u8{"--dump-parse"})) |value| {
            dump_parse_filename = value;
        } else if (try parser.argWithValue(arg, &[_][]const u8{"--dump-codegen"})) |value| {
            dump_codegen_filename = value;
        } else if (try parser.argWithValue(arg, &[_][]const u8{"--color"})) |value| {
            if (std.mem.eql(u8, value, "auto")) {
                color = .auto;
            } else if (std.mem.eql(u8, value, "always")) {
                color = .always;
            } else if (std.mem.eql(u8, value, "never")) {
                color = .never;
            } else {
                return parser.argError("invalid value '{}' for '{}'; must be one of 'auto', 'always', 'never'\n", .{ value, arg });
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return parser.argError("unrecognized option '{}'\n", .{arg});
        } else {
            script_filename = arg;
        }
    }

    if (help) {
        defer arena.deinit();
        var stdout = std.io.getStdOut().outStream();
        try usage(&stdout, parser.program);
        return null;
    }

    return Options{
        .arena = arena,
        .script_filename = script_filename orelse return parser.argError("missing file operand\n", .{}),
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

    const maybe_options = parseOptions(stderr, allocator) catch |err| {
        if (err != error.ArgError) stderr.print("error while parsing args: {}\n", .{err}) catch {};
        return 1;
    };
    const options = maybe_options orelse return 0;
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
