const std = @import("std");
const zang = @import("zang");
const zangscript = @import("zangscript");
const common = @import("common.zig");
const c = @import("common/c.zig");

pub const AUDIO_FORMAT: zang.AudioFormat = .signed16_lsb;
pub const AUDIO_SAMPLE_RATE = 44100;
pub const AUDIO_BUFFER_SIZE = 1024;

pub const DESCRIPTION =
    \\example_script_runtime
    \\
    \\Play a scripted sound module with the keyboard.
;

const a4 = 440.0;

const builtin_packages = [_]zangscript.BuiltinPackage{
    zangscript.zang_builtin_package,
};

pub const MainModule = struct {
    pub const num_outputs = 1;
    pub const num_temps = 4;
    pub const Params = [3]zangscript.Value;

    ok: bool,
    key: ?i32,
    iq: zang.Notes(Params).ImpulseQueue,
    idgen: zang.IdGenerator,
    instr: zangscript.ScriptModule,
    trig: zang.Trigger(Params),

    pub fn init() MainModule {
        var allocator = std.heap.page_allocator;
        const filename = "examples/script_runtime.txt";
        const contents = std.fs.cwd().readFileAlloc(allocator, filename, 16 * 1024 * 1024) catch |err| {
            std.debug.warn("failed to read file: {}\n", .{err});
            var self: MainModule = undefined;
            self.ok = false;
            return self;
        };
        //defer allocator.free(contents);
        const source: zangscript.Source = .{ .filename = filename, .contents = contents };
        var script = zangscript.compile(source, &builtin_packages, allocator) catch |err| {
            if (err != error.Failed) std.debug.warn("{}\n", .{err});
            var self: MainModule = undefined;
            self.ok = false;
            return self;
        };
        //defer script.deinit();
        var script_ptr = allocator.create(zangscript.CompiledScript) catch @panic("alloc failed");
        script_ptr.* = script;
        const module_index = for (script.modules) |module, i| {
            if (std.mem.eql(u8, module.name, "Instrument")) break i;
        } else {
            std.debug.warn("could not find module \"Instrument\"\n", .{});
            var self: MainModule = undefined;
            self.ok = false;
            return self;
        };
        return .{
            .ok = true,
            .key = null,
            .iq = zang.Notes(Params).ImpulseQueue.init(),
            .idgen = zang.IdGenerator.init(),
            .instr = zangscript.ScriptModule.init(script_ptr, module_index, &builtin_packages, allocator) catch @panic("ScriptModule init failed"),
            .trig = zang.Trigger(Params).init(),
        };
    }

    pub fn reset(self: *MainModule) void {
        self.* = init();
    }

    pub fn paint(self: *MainModule, span: zang.Span, outputs: [num_outputs][]f32, temps: [num_temps][]f32) void {
        if (!self.ok) {
            return;
        }

        var ctr = self.trig.counter(span, self.iq.consume());
        while (self.trig.next(&ctr)) |result| {
            self.instr.paint(result.span, &outputs, &temps, result.note_id_changed, &result.params);
        }
    }

    pub fn keyEvent(self: *MainModule, key: i32, down: bool, impulse_frame: usize) void {
        if (down and key == c.SDLK_SPACE) {
            self.reset();
            return;
        }
        if (!self.ok) {
            return;
        }
        const rel_freq = common.getKeyRelFreq(key) orelse return;
        if (down or (if (self.key) |nh| nh == key else false)) {
            self.key = if (down) key else null;

            self.iq.push(impulse_frame, self.idgen.nextId(), [_]zangscript.Value{
                .{ .constant = AUDIO_SAMPLE_RATE },
                .{ .cob = zang.constant(a4 * rel_freq) },
                .{ .boolean = down },
            });
        }
    }
};
