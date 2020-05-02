const std = @import("std");
const zang = @import("../zang.zig");
const Source = @import("tokenize.zig").Source;
const ParseResult = @import("parse.zig").ParseResult;
const CodeGenResult = @import("codegen.zig").CodeGenResult;
const BufferDest = @import("codegen.zig").BufferDest;
const ExpressionResult = @import("codegen.zig").ExpressionResult;

pub const Script = struct {
    source: Source,
    parse_result: ParseResult,
    codegen_result: CodeGenResult,
};

// TODO replace this with some vtable-like system?
const ModuleInstance = union(enum) {
    script_module: ScriptModule,
    // TODO the latter should be gotten from builtin packages
    envelope: zang.Envelope,
    filter: zang.Filter,
    gate: zang.Gate,
    pulse_osc: zang.PulseOsc,
    sine_osc: zang.SineOsc,
};

pub const ScriptModule = struct {
    // these might have to change to functions to get them to work with script modules...
    pub const num_outputs = 1;
    pub const num_temps = 10;
    pub const Params = struct {
        sample_rate: f32,
        freq: zang.ConstantOrBuffer,
        note_on: bool,
        attack: zang.PaintCurve,
    };

    allocator: *std.mem.Allocator, // don't use this in the audio thread (paint method)
    script: *const Script,
    module_index: usize,
    module_instances: []ModuleInstance,

    pub fn init(script: *const Script, module_index: usize, allocator: *std.mem.Allocator) !ScriptModule {
        const module = script.parse_result.modules[module_index];
        const inner = switch (script.codegen_result.module_results[module_index].inner) {
            .builtin => @panic("builtin passed to ScriptModule"),
            .custom => |x| x,
        };
        var module_instances = try allocator.alloc(ModuleInstance, inner.resolved_fields.len);
        for (inner.resolved_fields) |field_module_index, i| {
            const field_module_name = script.parse_result.modules[field_module_index].name;
            if (std.mem.eql(u8, field_module_name, "Envelope")) {
                module_instances[i] = .{ .envelope = zang.Envelope.init() };
            } else if (std.mem.eql(u8, field_module_name, "Filter")) {
                module_instances[i] = .{ .filter = zang.Filter.init() };
            } else if (std.mem.eql(u8, field_module_name, "Gate")) {
                module_instances[i] = .{ .gate = zang.Gate.init() };
            } else if (std.mem.eql(u8, field_module_name, "PulseOsc")) {
                module_instances[i] = .{ .pulse_osc = zang.PulseOsc.init() };
            } else if (std.mem.eql(u8, field_module_name, "SineOsc")) {
                module_instances[i] = .{ .sine_osc = zang.SineOsc.init() };
            } else {
                @panic("not implemented");
            }
        }
        return ScriptModule{
            .allocator = allocator,
            .script = script,
            .module_index = module_index,
            .module_instances = module_instances,
        };
    }

    const PaintArgs = struct {
        span: zang.Span,
        outputs: [num_outputs][]f32,
        temps: [num_temps][]f32,
        temp_floats: []f32,
        note_id_changed: bool,
        params: Params,
    };

    pub fn paint(
        self: *ScriptModule,
        span: zang.Span,
        outputs: [num_outputs][]f32,
        temps: [num_temps][]f32,
        note_id_changed: bool,
        params: Params,
    ) void {
        var temp_floats: [50]f32 = undefined; // FIXME - use the num_temp_floats from codegen result
        const p: PaintArgs = .{
            .span = span,
            .outputs = outputs,
            .temps = temps,
            .note_id_changed = note_id_changed,
            .params = params,
            .temp_floats = &temp_floats,
        };
        const inner = switch (self.script.codegen_result.module_results[self.module_index].inner) {
            .builtin => unreachable,
            .custom => |x| x,
        };
        for (inner.instructions) |instr| {
            switch (instr) {
                .copy_buffer => |x| {
                    zang.copy(span, getOut(p, x.out), self.getResultAsBuffer(p, x.in));
                },
                .float_to_buffer => |x| {
                    zang.set(span, getOut(p, x.out), self.getResultAsFloat(p, x.in));
                },
                .cob_to_buffer => |x| {
                    var out = getOut(p, x.out);
                    switch (self.getParam(zang.ConstantOrBuffer, p.params, x.in_self_param).?) {
                        .constant => |v| zang.set(span, out, v),
                        .buffer => |v| zang.copy(span, out, v),
                    }
                },
                .negate_float_to_float => |x| {
                    temp_floats[x.out.temp_float_index] = -self.getResultAsFloat(p, x.a);
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
                    temp_floats[x.out.temp_float_index] = switch (x.op) {
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
                .call => |x| {
                    var out = getOut(p, x.out);
                    const callee_module_index = inner.resolved_fields[x.field_index];
                    switch (self.module_instances[x.field_index]) {
                        .script_module => @panic("calling script_module not implemented"),
                        .envelope => |*m| self.call(p, zang.Envelope, m, x.args, callee_module_index, out),
                        .filter => |*m| self.call(p, zang.Filter, m, x.args, callee_module_index, out),
                        .gate => |*m| self.call(p, zang.Gate, m, x.args, callee_module_index, out),
                        .pulse_osc => |*m| self.call(p, zang.PulseOsc, m, x.args, callee_module_index, out),
                        .sine_osc => |*m| self.call(p, zang.SineOsc, m, x.args, callee_module_index, out),
                    }
                },
                .delay_begin => @panic("delay_begin not implemented"), // TODO
                .delay_end => @panic("delay_end not implemented"), // TODO
            }
        }
    }

    fn getOut(p: PaintArgs, buffer_dest: BufferDest) []f32 {
        return switch (buffer_dest) {
            .temp_buffer_index => |i| p.temps[i],
            .output_index => |i| p.outputs[i],
        };
    }

    fn call(self: *ScriptModule, p: PaintArgs, comptime T: type, m: *T, args: []const ExpressionResult, callee_module_index: usize, out: []f32) void {
        var callee_params: T.Params = undefined;
        inline for (@typeInfo(T.Params).Struct.fields) |field| {
            // get the index of this callee param in the runtime stuff
            const callee_module = self.script.parse_result.modules[callee_module_index];
            const callee_param_index = blk: {
                for (callee_module.params) |callee_param, i| {
                    if (std.mem.eql(u8, field.name, callee_param.name)) {
                        break :blk i;
                    }
                }
                unreachable;
            };
            const arg = args[callee_param_index]; // args are "in the order of the callee module's params".
            switch (field.field_type) {
                bool => @field(callee_params, field.name) = self.getResultAsBool(p, arg),
                f32 => @field(callee_params, field.name) = self.getResultAsFloat(p, arg),
                []const f32 => @field(callee_params, field.name) = self.getResultAsBuffer(p, arg),
                zang.ConstantOrBuffer => @field(callee_params, field.name) = self.getResultAsCob(p, arg),
                else => switch (@typeInfo(field.field_type)) {
                    .Enum => @field(callee_params, field.name) = self.getResultAsEnum(p, arg, field.field_type),
                    .Union => @field(callee_params, field.name) = self.getResultAsUnion(p, arg, field.field_type),
                    else => unreachable,
                },
            }
        }
        zang.zero(p.span, out);
        // TODO pass temps
        m.paint(p.span, [1][]f32{out}, .{}, p.note_id_changed, callee_params);
    }

    fn getParam(self: *const ScriptModule, comptime T: type, params: Params, param_index: usize) ?T {
        const param_name = self.script.parse_result.modules[self.module_index].params[param_index].name;
        inline for (@typeInfo(Params).Struct.fields) |field| {
            if (field.field_type != T) continue;
            if (std.mem.eql(u8, field.name, param_name)) return @field(params, field.name);
        }
        return null;
    }

    // TODO in the getResult* functions, the unreachables can be hit if the ScriptModule.Params struct
    // doesn't match the script params. we should be validating the Params beforehand or something.

    fn getResultAsBuffer(self: *const ScriptModule, p: PaintArgs, result: ExpressionResult) []const f32 {
        return switch (result) {
            .temp_buffer => |temp_ref| p.temps[temp_ref.index],
            .self_param => |param_index| self.getParam([]const f32, p.params, param_index).?,
            .nothing, .temp_float, .literal_boolean, .literal_number, .literal_enum_value => unreachable,
        };
    }

    fn getResultAsFloat(self: *const ScriptModule, p: PaintArgs, result: ExpressionResult) f32 {
        return switch (result) {
            .literal_number => |literal| std.fmt.parseFloat(f32, literal.verbatim) catch unreachable,
            .temp_float => |temp_ref| p.temp_floats[temp_ref.index],
            .self_param => |param_index| self.getParam(f32, p.params, param_index).?,
            .nothing, .temp_buffer, .literal_boolean, .literal_enum_value => unreachable,
        };
    }

    fn getResultAsCob(self: *const ScriptModule, p: PaintArgs, result: ExpressionResult) zang.ConstantOrBuffer {
        return switch (result) {
            .temp_buffer => |temp_ref| zang.buffer(p.temps[temp_ref.index]),
            .temp_float => |temp_ref| zang.constant(p.temp_floats[temp_ref.index]),
            .literal_number => |literal| zang.constant(std.fmt.parseFloat(f32, literal.verbatim) catch unreachable),
            .self_param => |param_index| {
                if (self.getParam([]const f32, p.params, param_index)) |v| return zang.buffer(v);
                if (self.getParam(f32, p.params, param_index)) |v| return zang.constant(v);
                unreachable;
            },
            .nothing, .literal_boolean, .literal_enum_value => unreachable,
        };
    }

    fn getResultAsBool(self: *const ScriptModule, p: PaintArgs, result: ExpressionResult) bool {
        return switch (result) {
            .literal_boolean => |v| v,
            .self_param => |param_index| self.getParam(bool, p.params, param_index).?,
            .nothing, .temp_buffer, .temp_float, .literal_number, .literal_enum_value => unreachable,
        };
    }

    fn getResultAsEnum(self: *const ScriptModule, p: PaintArgs, result: ExpressionResult, comptime T: type) T {
        return switch (result) {
            .literal_enum_value => |v| {
                inline for (@typeInfo(T).Enum.fields) |field, i| {
                    if (std.mem.eql(u8, v.label, field.name)) {
                        return @intToEnum(T, i);
                    }
                }
                unreachable;
            },
            .self_param => |param_index| self.getParam(T, p.params, param_index).?,
            .nothing, .temp_buffer, .temp_float, .literal_boolean, .literal_number => unreachable,
        };
    }

    fn getResultAsUnion(self: *const ScriptModule, p: PaintArgs, result: ExpressionResult, comptime T: type) T {
        return switch (result) {
            .literal_enum_value => |v| {
                inline for (@typeInfo(T).Union.fields) |field, i| {
                    if (std.mem.eql(u8, v.label, field.name)) {
                        switch (field.field_type) {
                            void => return @unionInit(T, field.name, {}),
                            f32 => return @unionInit(T, field.name, getResultAsFloat(self, p, v.payload.?.*)),
                            // the above are the only payload types allowed by the language so far
                            else => @panic("getResultAsUnion: field type not implemented: " ++ @typeName(field.field_type)),
                        }
                    }
                }
                unreachable;
            },
            .self_param => |param_index| self.getParam(T, p.params, param_index).?,
            .nothing, .temp_buffer, .temp_float, .literal_boolean, .literal_number => unreachable,
        };
    }
};
