const std = @import("std");
const zang = @import("../zang.zig");
const Source = @import("tokenize.zig").Source;
const BuiltinPackage = @import("builtins.zig").BuiltinPackage;
const BuiltinEnumValue = @import("builtins.zig").BuiltinEnumValue;
const ParamType = @import("parse.zig").ParamType;
const ModuleParam = @import("parse.zig").ModuleParam;
const ParseResult = @import("parse.zig").ParseResult;
const CodeGenResult = @import("codegen.zig").CodeGenResult;
const BufferDest = @import("codegen.zig").BufferDest;
const ExpressionResult = @import("codegen.zig").ExpressionResult;
const Instruction = @import("codegen.zig").Instruction;
const CodeGenCustomModuleInner = @import("codegen.zig").CodeGenCustomModuleInner;
const CompiledScript = @import("compile.zig").CompiledScript;

pub const Value = union(enum) {
    constant: f32,
    buffer: []const f32,
    cob: zang.ConstantOrBuffer,
    boolean: bool,
    one_of: struct { label: []const u8, payload: ?f32 },

    // turn a Value into a zig value
    pub fn resolve(value: Value, comptime P: type) P {
        switch (P) {
            bool => switch (value) {
                .boolean => |v| return v,
                else => unreachable,
            },
            f32 => switch (value) {
                .constant => |v| return v,
                else => unreachable,
            },
            []const f32 => switch (value) {
                .buffer => |v| return v,
                else => unreachable,
            },
            zang.ConstantOrBuffer => switch (value) {
                .cob => |v| return v,
                else => unreachable,
            },
            else => switch (@typeInfo(P)) {
                .Enum => |enum_info| {
                    switch (value) {
                        .one_of => |v| {
                            inline for (enum_info.fields) |enum_field, i| {
                                if (std.mem.eql(u8, v.label, enum_field.name)) {
                                    return @intToEnum(P, i);
                                }
                            }
                            unreachable;
                        },
                        else => unreachable,
                    }
                },
                .Union => |union_info| {
                    switch (value) {
                        .one_of => |v| {
                            inline for (union_info.fields) |union_field, i| {
                                if (std.mem.eql(u8, v.label, union_field.name)) {
                                    switch (union_field.field_type) {
                                        void => return @unionInit(P, union_field.name, {}),
                                        f32 => return @unionInit(P, union_field.name, v.payload.?),
                                        // the above are the only payload types allowed by the language so far
                                        else => unreachable,
                                    }
                                }
                            }
                            unreachable;
                        },
                        else => unreachable,
                    }
                },
                else => unreachable,
            },
        }
    }

    // turn a zig value into a Value
    fn fromZig(param_type: ParamType, zig_value: var) ?Value {
        switch (param_type) {
            .boolean => if (@TypeOf(zig_value) == bool) return Value{ .boolean = zig_value },
            .buffer => if (@TypeOf(zig_value) == []const f32) return Value{ .buffer = zig_value },
            .constant => if (@TypeOf(zig_value) == f32) return Value{ .constant = zig_value },
            .constant_or_buffer => if (@TypeOf(zig_value) == zang.ConstantOrBuffer) return Value{ .cob = zig_value },
            .one_of => |builtin_enum| {
                switch (@typeInfo(@TypeOf(zig_value))) {
                    .Enum => |enum_info| {
                        // just check if the current value of `zig_value` fits structurally
                        const label = @tagName(zig_value);
                        for (builtin_enum.values) |bev| {
                            if (std.mem.eql(u8, bev.label, label) and bev.payload_type == .none) {
                                return Value{ .one_of = .{ .label = label, .payload = null } };
                            }
                        }
                    },
                    .Union => |union_info| {
                        // just check if the current value of `zig_value` fits structurally
                        for (builtin_enum.values) |bev| {
                            inline for (union_info.fields) |field, i| {
                                if (@enumToInt(zig_value) == i and std.mem.eql(u8, bev.label, field.name)) {
                                    return payloadFromZig(bev, @field(zig_value, field.name));
                                }
                            }
                        }
                    },
                    else => {},
                }
            },
        }
        return null;
    }

    fn payloadFromZig(bev: BuiltinEnumValue, zig_payload: var) ?Value {
        switch (bev.payload_type) {
            .none => {
                if (@TypeOf(zig_payload) == void) {
                    return Value{ .one_of = .{ .label = bev.label, .payload = null } };
                }
            },
            .f32 => {
                if (@TypeOf(zig_payload) == f32) {
                    return Value{ .one_of = .{ .label = bev.label, .payload = zig_payload } };
                }
            },
        }
        return null;
    }
};

pub const ModuleBase = struct {
    allocator: *std.mem.Allocator,
    num_outputs: usize,
    num_temps: usize,
    params: []const ModuleParam,
    deinitFn: fn (base: *ModuleBase) void,
    paintFn: fn (base: *ModuleBase, span: zang.Span, outputs: []const []f32, temps: []const []f32, note_id_changed: bool, params: []const Value) void,

    pub fn deinit(base: *ModuleBase) void {
        base.deinitFn(base);
        // destroy the allocation created by initModule. technically we're not passing the same object
        // that was created (it was the full "child class" object that was created), but since they
        // start on the same memory address, this works (the allocator remembers the allocation size)
        base.allocator.destroy(base);
    }

    pub fn paint(base: *ModuleBase, span: zang.Span, outputs: []const []f32, temps: []const []f32, note_id_changed: bool, params: []const Value) void {
        base.paintFn(base, span, outputs, temps, note_id_changed, params);
    }

    // convenience function for interfacing with runtime scripts from zig code.
    // you give it an impromptu struct of params and it will validate and convert that into the array of Values that the runtime expects
    pub fn makeParams(self: *const ModuleBase, comptime T: type, params: T) ?[@typeInfo(T).Struct.fields.len]Value {
        const struct_fields = @typeInfo(T).Struct.fields;
        var values: [struct_fields.len]Value = undefined;
        for (self.params) |param, i| {
            var found = false;
            inline for (struct_fields) |field| {
                if (std.mem.eql(u8, field.name, param.name)) {
                    values[i] = Value.fromZig(param.param_type, @field(params, field.name)) orelse {
                        std.debug.warn("makeParams: type mismatch on param \"{}\"\n", .{param.name});
                        return null;
                    };
                    found = true;
                }
            }
            if (!found) {
                std.debug.warn("makeParams: missing param \"{}\"\n", .{param.name});
                return null;
            }
        }
        return values;
    }
};

pub fn initModule(
    script: *const CompiledScript,
    module_index: usize,
    comptime builtin_packages: []const BuiltinPackage,
    allocator: *std.mem.Allocator,
) !*ModuleBase {
    const inner = switch (script.module_results[module_index].inner) {
        .builtin => {
            const module_name = script.modules[module_index].name;
            inline for (builtin_packages) |pkg| {
                inline for (pkg.builtins) |builtin| {
                    if (std.mem.eql(u8, builtin.name, module_name)) {
                        const Impl = BuiltinModule(builtin.T);
                        var impl = try allocator.create(Impl);
                        impl.* = Impl.init(script, module_index, allocator);
                        return &impl.base;
                    }
                }
            }
        },
        .custom => |x| {
            var impl = try allocator.create(ScriptModule);
            errdefer allocator.destroy(impl);
            impl.* = try ScriptModule.init(script, module_index, builtin_packages, allocator);
            return &impl.base;
        },
    };
    unreachable;
}

fn BuiltinModule(comptime T: type) type {
    return struct {
        base: ModuleBase,
        mod: T,

        fn init(script: *const CompiledScript, module_index: usize, allocator: *std.mem.Allocator) @This() {
            return @This(){
                .base = .{
                    .allocator = allocator,
                    .num_outputs = T.num_outputs,
                    .num_temps = T.num_temps,
                    .params = script.modules[module_index].params,
                    .deinitFn = deinitFn,
                    .paintFn = paintFn,
                },
                .mod = T.init(),
            };
        }

        fn deinitFn(base: *ModuleBase) void {}

        fn paintFn(
            base: *ModuleBase,
            span: zang.Span,
            outputs_slice: []const []f32,
            temps_slice: []const []f32,
            note_id_changed: bool,
            param_values: []const Value,
        ) void {
            var self = @fieldParentPtr(@This(), "base", base);

            std.debug.assert(outputs_slice.len == T.num_outputs);
            var outputs: [T.num_outputs][]f32 = undefined;
            std.mem.copy([]f32, &outputs, outputs_slice);

            std.debug.assert(temps_slice.len == T.num_temps);
            var temps: [T.num_temps][]f32 = undefined;
            std.mem.copy([]f32, &temps, temps_slice);

            var params: T.Params = undefined;
            inline for (@typeInfo(T.Params).Struct.fields) |field| {
                const param_index = getParamIndex(self.base.params, field.name);
                @field(params, field.name) = param_values[param_index].resolve(field.field_type);
            }

            self.mod.paint(span, outputs, temps, note_id_changed, params);
        }

        fn getParamIndex(params: []const ModuleParam, name: []const u8) usize {
            for (params) |param, i| {
                if (std.mem.eql(u8, name, param.name)) {
                    return i;
                }
            }
            unreachable;
        }
    };
}

const ScriptModule = struct {
    base: ModuleBase,
    arena: std.heap.ArenaAllocator,
    script: *const CompiledScript,
    module_index: usize,
    module_instances: []*ModuleBase,
    delay_instances: []zang.Delay(11025),
    temp_floats: []f32,
    callee_temps: [][]f32,
    callee_params: []Value,

    fn init(
        script: *const CompiledScript,
        module_index: usize,
        comptime builtin_packages: []const BuiltinPackage,
        inner_allocator: *std.mem.Allocator,
    ) error{OutOfMemory}!ScriptModule {
        const inner = switch (script.module_results[module_index].inner) {
            .builtin => unreachable,
            .custom => |x| x,
        };

        var arena = std.heap.ArenaAllocator.init(inner_allocator);
        errdefer arena.deinit();

        var module_instances = try arena.allocator.alloc(*ModuleBase, inner.resolved_fields.len);

        var num_initialized_fields: usize = 0;
        errdefer for (module_instances[0..num_initialized_fields]) |module_instance| {
            module_instance.deinit();
        };

        for (inner.resolved_fields) |field_module_index, i| {
            module_instances[i] = try initModule(script, field_module_index, builtin_packages, inner_allocator);
            num_initialized_fields += 1;
        }

        var delay_instances = try arena.allocator.alloc(zang.Delay(11025), inner.delays.len);
        for (inner.delays) |delay_decl, i| {
            // ignoring delay_decl.num_samples because we need a comptime value
            delay_instances[i] = zang.Delay(11025).init();
        }

        var temp_floats = try arena.allocator.alloc(f32, script.module_results[module_index].num_temp_floats);

        var most_callee_temps: usize = 0;
        var most_callee_params: usize = 0;
        for (inner.resolved_fields) |field_module_index| {
            const callee_temps = script.module_results[field_module_index].num_temps;
            if (callee_temps > most_callee_temps) {
                most_callee_temps = callee_temps;
            }
            const callee_params = script.modules[field_module_index].params;
            if (callee_params.len > most_callee_params) {
                most_callee_params = callee_params.len;
            }
        }
        var callee_temps = try arena.allocator.alloc([]f32, most_callee_temps);
        var callee_params = try arena.allocator.alloc(Value, most_callee_params);

        return ScriptModule{
            .base = .{
                .allocator = inner_allocator,
                .num_outputs = script.module_results[module_index].num_outputs,
                .num_temps = script.module_results[module_index].num_temps,
                .params = script.modules[module_index].params,
                .deinitFn = deinitFn,
                .paintFn = paintFn,
            },
            .arena = arena,
            .script = script,
            .module_index = module_index,
            .module_instances = module_instances,
            .delay_instances = delay_instances,
            .temp_floats = temp_floats,
            .callee_temps = callee_temps,
            .callee_params = callee_params,
        };
    }

    fn deinitFn(base: *ModuleBase) void {
        var self = @fieldParentPtr(ScriptModule, "base", base);
        for (self.module_instances) |module_instance| {
            module_instance.deinit();
        }
        self.arena.deinit();
    }

    const PaintArgs = struct {
        outputs: []const []f32,
        temps: []const []f32,
        note_id_changed: bool,
        params: []const Value,
    };

    fn paintFn(
        base: *ModuleBase,
        span: zang.Span,
        outputs: []const []f32,
        temps: []const []f32,
        note_id_changed: bool,
        params: []const Value,
    ) void {
        var self = @fieldParentPtr(ScriptModule, "base", base);

        std.debug.assert(outputs.len == self.script.module_results[self.module_index].num_outputs);
        std.debug.assert(temps.len == self.script.module_results[self.module_index].num_temps);

        const inner = switch (self.script.module_results[self.module_index].inner) {
            .builtin => unreachable,
            .custom => |x| x,
        };
        const p: PaintArgs = .{
            .outputs = outputs,
            .temps = temps,
            .note_id_changed = note_id_changed,
            .params = params,
        };
        for (inner.instructions) |instr| {
            self.paintInstruction(inner, p, span, instr);
        }
    }

    fn paintInstruction(self: *const ScriptModule, inner: CodeGenCustomModuleInner, p: PaintArgs, span: zang.Span, instr: Instruction) void {
        switch (instr) {
            .copy_buffer => |x| {
                zang.copy(span, getOut(p, x.out), self.getResultAsBuffer(p, x.in));
            },
            .float_to_buffer => |x| {
                zang.set(span, getOut(p, x.out), self.getResultAsFloat(p, x.in));
            },
            .cob_to_buffer => |x| {
                var out = getOut(p, x.out);
                switch (p.params[x.in_self_param]) {
                    .cob => |cob| switch (cob) {
                        .constant => |v| zang.set(span, out, v),
                        .buffer => |v| zang.copy(span, out, v),
                    },
                    else => unreachable,
                }
            },
            .call => |x| {
                var out = getOut(p, x.out);

                const callee_module_index = inner.resolved_fields[x.field_index];
                const callee_base = self.module_instances[x.field_index];

                for (x.temps) |n, i| {
                    self.callee_temps[i] = p.temps[n];
                }

                for (x.args) |arg, i| {
                    const param_type = self.script.modules[callee_module_index].params[i].param_type;
                    self.callee_params[i] = self.getResultValue(p, param_type, arg);
                }

                zang.zero(span, out);
                callee_base.paintFn(
                    callee_base,
                    span,
                    &[1][]f32{out},
                    self.callee_temps[0..x.temps.len],
                    p.note_id_changed,
                    self.callee_params[0..x.args.len],
                );
            },
            .negate_float_to_float => |x| {
                self.temp_floats[x.out.temp_float_index] = -self.getResultAsFloat(p, x.a);
            },
            .negate_buffer_to_buffer => |x| {
                var out = getOut(p, x.out);
                const a = self.getResultAsBuffer(p, x.a);
                var i: usize = span.start;
                while (i < span.end) : (i += 1) {
                    out[i] = -a[i];
                }
            },
            .arith_float_float => |x| {
                const a = self.getResultAsFloat(p, x.a);
                const b = self.getResultAsFloat(p, x.b);
                self.temp_floats[x.out.temp_float_index] = switch (x.op) {
                    .add => a + b,
                    .sub => a - b,
                    .mul => a * b,
                    .div => a / b,
                    .pow => std.math.pow(f32, a, b),
                };
            },
            .arith_float_buffer => |x| {
                var out = getOut(p, x.out);
                const a = self.getResultAsFloat(p, x.a);
                const b = self.getResultAsBuffer(p, x.b);
                switch (x.op) {
                    .add => {
                        zang.zero(span, out);
                        zang.addScalar(span, out, b, a);
                    },
                    .sub => {
                        var i: usize = span.start;
                        while (i < span.end) : (i += 1) {
                            out[i] = a - b[i];
                        }
                    },
                    .mul => {
                        zang.zero(span, out);
                        zang.multiplyScalar(span, out, b, a);
                    },
                    .div => {
                        var i: usize = span.start;
                        while (i < span.end) : (i += 1) {
                            out[i] = a / b[i];
                        }
                    },
                    .pow => {
                        var i: usize = span.start;
                        while (i < span.end) : (i += 1) {
                            out[i] = std.math.pow(f32, a, b[i]);
                        }
                    },
                }
            },
            .arith_buffer_float => |x| {
                var out = getOut(p, x.out);
                const a = self.getResultAsBuffer(p, x.a);
                const b = self.getResultAsFloat(p, x.b);
                switch (x.op) {
                    .add => {
                        zang.zero(span, out);
                        zang.addScalar(span, out, a, b);
                    },
                    .sub => {
                        var i: usize = span.start;
                        while (i < span.end) : (i += 1) {
                            out[i] = a[i] - b;
                        }
                    },
                    .mul => {
                        zang.zero(span, out);
                        zang.multiplyScalar(span, out, a, b);
                    },
                    .div => {
                        var i: usize = span.start;
                        while (i < span.end) : (i += 1) {
                            out[i] = a[i] / b;
                        }
                    },
                    .pow => {
                        var i: usize = span.start;
                        while (i < span.end) : (i += 1) {
                            out[i] = std.math.pow(f32, a[i], b);
                        }
                    },
                }
            },
            .arith_buffer_buffer => |x| {
                var out = getOut(p, x.out);
                const a = self.getResultAsBuffer(p, x.a);
                const b = self.getResultAsBuffer(p, x.b);
                switch (x.op) {
                    .add => {
                        zang.zero(span, out);
                        zang.add(span, out, a, b);
                    },
                    .sub => {
                        var i: usize = span.start;
                        while (i < span.end) : (i += 1) {
                            out[i] = a[i] - b[i];
                        }
                    },
                    .mul => {
                        zang.zero(span, out);
                        zang.multiply(span, out, a, b);
                    },
                    .div => {
                        var i: usize = span.start;
                        while (i < span.end) : (i += 1) {
                            out[i] = a[i] / b[i];
                        }
                    },
                    .pow => {
                        var i: usize = span.start;
                        while (i < span.end) : (i += 1) {
                            out[i] = std.math.pow(f32, a[i], b[i]);
                        }
                    },
                }
            },
            .delay => |x| {
                var out = getOut(p, x.out);
                zang.zero(span, out);
                var start = span.start;
                const end = span.end;
                while (start < end) {
                    zang.zero(zang.Span.init(start, end), p.temps[x.feedback_out_temp_buffer_index]);
                    zang.zero(zang.Span.init(start, end), p.temps[x.feedback_temp_buffer_index]);
                    const samples_read = self.delay_instances[x.delay_index].readDelayBuffer(p.temps[x.feedback_temp_buffer_index][start..end]);
                    const inner_span = zang.Span.init(start, start + samples_read);
                    for (x.instructions) |sub_instr| {
                        self.paintInstruction(inner, p, inner_span, sub_instr);
                    }
                    self.delay_instances[x.delay_index].writeDelayBuffer(p.temps[x.feedback_out_temp_buffer_index][start .. start + samples_read]);
                    start += samples_read;
                }
            },
        }
    }

    fn getOut(p: PaintArgs, buffer_dest: BufferDest) []f32 {
        return switch (buffer_dest) {
            .temp_buffer_index => |i| p.temps[i],
            .output_index => |i| p.outputs[i],
        };
    }

    fn getResultValue(self: *const ScriptModule, p: PaintArgs, param_type: ParamType, result: ExpressionResult) Value {
        switch (param_type) {
            .boolean => return .{ .boolean = self.getResultAsBool(p, result) },
            .buffer => return .{ .buffer = self.getResultAsBuffer(p, result) },
            .constant => return .{ .constant = self.getResultAsFloat(p, result) },
            .constant_or_buffer => return .{ .cob = self.getResultAsCob(p, result) },
            .one_of => |builtin_enum| {
                return switch (result) {
                    .literal_enum_value => |literal| {
                        const payload = if (literal.payload) |result_payload|
                            self.getResultAsFloat(p, result_payload.*)
                        else
                            null;
                        return .{ .one_of = .{ .label = literal.label, .payload = payload } };
                    },
                    .self_param => |param_index| switch (p.params[param_index]) {
                        .one_of => |v| return .{ .one_of = v },
                        .constant, .buffer, .cob, .boolean => unreachable,
                    },
                    .nothing, .temp_float, .temp_buffer, .literal_boolean, .literal_number => unreachable,
                };
            },
        }
    }

    fn getResultAsBuffer(self: *const ScriptModule, p: PaintArgs, result: ExpressionResult) []const f32 {
        return switch (result) {
            .temp_buffer => |temp_ref| p.temps[temp_ref.index],
            .self_param => |param_index| switch (p.params[param_index]) {
                .buffer => |v| v,
                .constant, .cob, .boolean, .one_of => unreachable,
            },
            .nothing, .temp_float, .literal_boolean, .literal_number, .literal_enum_value => unreachable,
        };
    }

    fn getResultAsFloat(self: *const ScriptModule, p: PaintArgs, result: ExpressionResult) f32 {
        return switch (result) {
            .literal_number => |literal| literal.value,
            .temp_float => |temp_ref| self.temp_floats[temp_ref.index],
            .self_param => |param_index| switch (p.params[param_index]) {
                .constant => |v| v,
                .buffer, .cob, .boolean, .one_of => unreachable,
            },
            .nothing, .temp_buffer, .literal_boolean, .literal_enum_value => unreachable,
        };
    }

    fn getResultAsCob(self: *const ScriptModule, p: PaintArgs, result: ExpressionResult) zang.ConstantOrBuffer {
        return switch (result) {
            .temp_buffer => |temp_ref| zang.buffer(p.temps[temp_ref.index]),
            .temp_float => |temp_ref| zang.constant(self.temp_floats[temp_ref.index]),
            .literal_number => |literal| zang.constant(literal.value),
            .self_param => |param_index| switch (p.params[param_index]) {
                .constant => |v| zang.constant(v),
                .buffer => |v| zang.buffer(v),
                .cob => |v| v,
                .boolean, .one_of => unreachable,
            },
            .nothing, .literal_boolean, .literal_enum_value => unreachable,
        };
    }

    fn getResultAsBool(self: *const ScriptModule, p: PaintArgs, result: ExpressionResult) bool {
        return switch (result) {
            .literal_boolean => |v| v,
            .self_param => |param_index| switch (p.params[param_index]) {
                .boolean => |v| v,
                .constant, .buffer, .cob, .one_of => unreachable,
            },
            .nothing, .temp_buffer, .temp_float, .literal_number, .literal_enum_value => unreachable,
        };
    }
};
