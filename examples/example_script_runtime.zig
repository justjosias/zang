const std = @import("std");
const zang = @import("zang");
const zangscript = @import("zangscript");
const common = @import("common.zig");
const c = @import("common/c.zig");
const modules = @import("modules.zig");

pub const AUDIO_FORMAT: zang.AudioFormat = .signed16_lsb;
pub const AUDIO_SAMPLE_RATE = 44100;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    \\example_script_runtime
    \\
    \\Play a scripted sound module with the keyboard.
    \\
    \\Press F5 to reload the script.
;

const a4 = 440.0;

const custom_builtin_package = zangscript.BuiltinPackage{
    .zig_package_name = "modules",
    .zig_import_path = "modules.zig",
    .builtins = &[_]zangscript.BuiltinModule{
        zangscript.getBuiltinModule(modules.FilteredSawtoothInstrument),
    },
    .enums = &[_]zangscript.BuiltinEnum{},
};

const builtin_packages = [_]zangscript.BuiltinPackage{
    zangscript.zang_builtin_package,
    custom_builtin_package,
};

pub const MainModule = struct {
    pub const num_outputs = 1;
    pub const num_temps = 10; // FIXME

    const filename = "examples/script.txt";
    const module_name = "Instrument";
    const Params = struct {
        sample_rate: f32,
        freq: zang.ConstantOrBuffer,
        note_on: bool,
    };

    allocator: *std.mem.Allocator,
    contents: []const u8,
    script: *zangscript.CompiledScript,

    key: ?i32,
    iq: zang.Notes(Params).ImpulseQueue,
    idgen: zang.IdGenerator,
    instr: *zangscript.ModuleBase,
    trig: zang.Trigger(Params),

    pub fn init() !MainModule {
        var allocator = std.heap.page_allocator;

        const contents = try std.fs.cwd().readFileAlloc(allocator, filename, 16 * 1024 * 1024);
        errdefer allocator.free(contents);

        var script = try zangscript.compile(filename, contents, &builtin_packages, allocator);
        errdefer script.deinit();

        var script_ptr = try allocator.create(zangscript.CompiledScript);
        script_ptr.* = script;

        const module_index = for (script.modules) |module, i| {
            if (std.mem.eql(u8, module.name, module_name)) break i;
        } else return error.ModuleNotFound;

        return MainModule{
            .allocator = allocator,
            .contents = contents,
            .script = script_ptr,
            .key = null,
            .iq = zang.Notes(Params).ImpulseQueue.init(),
            .idgen = zang.IdGenerator.init(),
            .instr = try zangscript.initModule(script_ptr, module_index, &builtin_packages, allocator),
            .trig = zang.Trigger(Params).init(),
        };
    }

    pub fn deinit(self: *MainModule) void {
        self.instr.deinit();
        self.script.deinit();
        self.allocator.destroy(self.script);
        self.allocator.free(self.contents);
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32) void {
        var ctr = self.trig.counter(span, self.iq.consume());
        while (self.trig.next(&ctr)) |result| {
            const params = self.instr.makeParams(Params, result.params) orelse break;

            self.instr.paint(result.span, &outputs, temps[0..self.instr.num_temps], result.note_id_changed, &params);
        }
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        const rel_freq = common.getKeyRelFreq(key) orelse return;

        if (down or (if (self.key) |nh| nh == key else false)) {
            self.key = if (down) key else null;

            self.iq.push(impulse_frame, self.idgen.nextId(), Params{
                .sample_rate = AUDIO_SAMPLE_RATE,
                .freq = zang.constant(a4 * rel_freq),
                .note_on = down,
            });
        }
    }
};
