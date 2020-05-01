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
        freq: f32,
        note_on: bool,
    };

    allocator: *std.mem.Allocator,
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
        const paint_args: PaintArgs = .{
            .span = span,
            .outputs = outputs,
            .temps = temps,
            .note_id_changed = note_id_changed,
            .params = params,
        };
        const inner = switch (self.script.codegen_result.module_results[self.module_index].inner) {
            .builtin => unreachable,
            .custom => |x| x,
        };
        for (inner.instructions) |instr| {
            switch (instr) {
                //.copy_buffer => |x| {
                //    try self.print("zang.copy({str}, {buffer_dest}, {expression_result});\n", .{ span, x.out, x.in });
                //},
                //.float_to_buffer => |x| {
                //    try self.print("zang.set({str}, {buffer_dest}, {expression_result});\n", .{ span, x.out, x.in });
                //},
                .cob_to_buffer => |x| {
                    var out = switch (x.out) {
                        .temp_buffer_index => |i| temps[i],
                        .output_index => |i| outputs[i],
                    };
                    const cob = blk: {
                        const param_name = self.script.parse_result.modules[self.module_index].params[x.in_self_param].name;
                        inline for (@typeInfo(Params).Struct.fields) |field| {
                            if (field.field_type != zang.ConstantOrBuffer) continue;
                            if (std.mem.eql(u8, field.name, param_name)) {
                                break :blk @field(params, field.name);
                            }
                        }
                        unreachable;
                    };
                    switch (cob) {
                        .constant => |v| zang.set(span, out, v),
                        .buffer => |v| zang.copy(span, out, v),
                    }
                },
                .call => |call| {
                    var out = getOut(paint_args, call.out);
                    const callee_module_index = inner.resolved_fields[call.field_index];
                    switch (self.module_instances[call.field_index]) {
                        .script_module => @panic("calling script_module not implemented"),
                        .envelope => |*m| self.callGeneric(paint_args, zang.Envelope, m, call.args, callee_module_index, out),
                        .filter => |*m| self.callGeneric(paint_args, zang.Filter, m, call.args, callee_module_index, out),
                        .gate => |*m| self.callGeneric(paint_args, zang.Gate, m, call.args, callee_module_index, out),
                        .pulse_osc => |*m| self.callGeneric(paint_args, zang.PulseOsc, m, call.args, callee_module_index, out),
                        .sine_osc => |*m| self.callGeneric(paint_args, zang.SineOsc, m, call.args, callee_module_index, out),
                    }
                },
                .arith_float_buffer => |x| {
                    switch (x.op) {
                        .add => {
                            var out = getOut(paint_args, x.out);
                            const a = self.getResultAsFloat(params, x.a);
                            const b = self.getResultAsBuffer(params, x.b, temps);
                            zang.zero(span, out);
                            zang.addScalar(span, out, b, a);
                        },
                        .mul => {
                            var out = getOut(paint_args, x.out);
                            const a = self.getResultAsFloat(params, x.a);
                            const b = self.getResultAsBuffer(params, x.b, temps);
                            zang.zero(span, out);
                            zang.multiplyScalar(span, out, b, a);
                        },
                        else => {
                            std.debug.warn("op: {}\n", .{x.op});
                            @panic("op not implemented");
                        },
                    }
                },
                .arith_buffer_float => |x| {
                    switch (x.op) {
                        .mul => {
                            var out = getOut(paint_args, x.out);
                            const a = self.getResultAsBuffer(params, x.a, temps);
                            const b = self.getResultAsFloat(params, x.b);
                            zang.zero(span, out);
                            zang.multiplyScalar(span, out, a, b);
                        },
                        else => {
                            std.debug.warn("op: {}\n", .{x.op});
                            @panic("op not implemented");
                        },
                    }
                },
                .arith_buffer_buffer => |x| {
                    switch (x.op) {
                        .mul => {
                            var out = getOut(paint_args, x.out);
                            const a = self.getResultAsBuffer(params, x.a, temps);
                            const b = self.getResultAsBuffer(params, x.b, temps);
                            zang.zero(span, out);
                            zang.multiply(span, out, a, b);
                        },
                        else => {
                            std.debug.warn("op: {}\n", .{x.op});
                            @panic("op not implemented");
                        },
                    }
                },
                else => {
                    std.debug.warn("not implemented: {}\n", .{instr});
                    @panic("instruction not implemented");
                },
            }
        }
    }

    fn getOut(p: PaintArgs, buffer_dest: BufferDest) []f32 {
        return switch (buffer_dest) {
            .temp_buffer_index => |i| p.temps[i],
            .output_index => |i| p.outputs[i],
        };
    }

    fn callGeneric(self: *ScriptModule, p: PaintArgs, comptime T: type, m: *T, args: []const ExpressionResult, callee_module_index: usize, out: []f32) void {
        const CalleeParams = T.Params;
        var callee_params: CalleeParams = undefined;
        inline for (@typeInfo(CalleeParams).Struct.fields) |field| {
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
            // args are "in the order of the callee module's params".
            switch (field.field_type) {
                bool => {
                    @field(callee_params, field.name) = self.getResultAsBool(p.params, args[callee_param_index]);
                },
                f32 => {
                    @field(callee_params, field.name) = self.getResultAsFloat(p.params, args[callee_param_index]);
                },
                []const f32 => {
                    @field(callee_params, field.name) = self.getResultAsBuffer(p.params, args[callee_param_index], p.temps);
                },
                zang.ConstantOrBuffer => {
                    @field(callee_params, field.name) = self.getResultAsCob(p.params, args[callee_param_index], p.temps);
                },
                else => switch (@typeInfo(field.field_type)) {
                    .Enum => {
                        @field(callee_params, field.name) = self.getResultAsEnum(p.params, args[callee_param_index], field.field_type);
                    },
                    .Union => {
                        @field(callee_params, field.name) = self.getResultAsUnion(p.params, args[callee_param_index], field.field_type);
                    },
                    else => {
                        std.debug.warn("field type: {}\n", .{@typeName(field.field_type)});
                        @panic("field type not implemented");
                    },
                },
            }
        }
        zang.zero(p.span, out);
        m.paint(p.span, [1][]f32{out}, .{}, p.note_id_changed, callee_params);
    }
    fn getResultAsBuffer(self: *const ScriptModule, params: Params, result: ExpressionResult, temps: [num_temps][]f32) []const f32 {
        return switch (result) {
            //.self_param => |self_param_index| self.getParamAsFloat(params, self_param_index),
            //.literal_number => |literal| std.fmt.parseFloat(f32, literal.verbatim) catch unreachable,
            .temp_buffer => |temp_ref| temps[temp_ref.index],
            else => {
                std.debug.warn("result: {}\n", .{result});
                @panic("value type not implemented");
            },
        };
    }
    fn getResultAsFloat(self: *const ScriptModule, params: Params, result: ExpressionResult) f32 {
        return switch (result) {
            .self_param => |self_param_index| self.getParamAsFloat(params, self_param_index),
            .literal_number => |literal| std.fmt.parseFloat(f32, literal.verbatim) catch unreachable,
            else => {
                std.debug.warn("result: {}\n", .{result});
                @panic("value type not implemented");
            },
        };
    }
    fn getResultAsCob(self: *const ScriptModule, params: Params, result: ExpressionResult, temps: [num_temps][]f32) zang.ConstantOrBuffer {
        return switch (result) {
            //.self_param => |self_param_index| self.getParamAsCob
            //    // TODO support buffers as well
            //    const f = self.getParamAsFloat(p.params, self_param_index);
            //    break :blk zang.constant(f);
            //},
            .literal_number => |literal| zang.constant(std.fmt.parseFloat(f32, literal.verbatim) catch unreachable),
            .temp_buffer => |temp_ref| zang.buffer(temps[temp_ref.index]),
            else => {
                std.debug.warn("result: {}\n", .{result});
                @panic("value type not implemented");
            },
        };
    }
    fn getResultAsBool(self: *const ScriptModule, params: Params, result: ExpressionResult) bool {
        return switch (result) {
            .self_param => |self_param_index| self.getParamAsBool(params, self_param_index),
            else => {
                std.debug.warn("result: {}\n", .{result});
                @panic("value type not implemented");
            },
        };
    }
    fn getResultAsEnum(self: *const ScriptModule, params: Params, result: ExpressionResult, comptime T: type) T {
        switch (result) {
            .literal_enum_value => |v| {
                inline for (@typeInfo(T).Enum.fields) |field, i| {
                    if (std.mem.eql(u8, v.label, field.name)) {
                        return @intToEnum(T, i);
                    }
                }
                unreachable;
            },
            else => {
                std.debug.warn("result: {}\n", .{result});
                @panic("value type not implemented");
            },
        }
    }
    fn getResultAsUnion(self: *const ScriptModule, params: Params, result: ExpressionResult, comptime T: type) T {
        switch (result) {
            .literal_enum_value => |v| {
                inline for (@typeInfo(T).Union.fields) |field, i| {
                    if (std.mem.eql(u8, v.label, field.name)) {
                        switch (field.field_type) {
                            void => return @unionInit(T, field.name, {}),
                            f32 => return @unionInit(T, field.name, getResultAsFloat(self, params, v.payload.?.*)),
                            else => {
                                std.debug.warn("field_type: {}\n", .{@typeName(field.field_type)});
                                @panic("field type not implemented");
                            },
                        }
                    }
                }
                unreachable;
            },
            else => {
                std.debug.warn("result: {}\n", .{result});
                @panic("value type not implemented");
            },
        }
    }
    //fn getParamAsBuffer(self: *const ScriptModule, params: Params, param_index: usize) f32 {
    //    const param_name = self.script.parse_result.modules[self.module_index].params[param_index].name;
    //    inline for (@typeInfo(Params).Struct.fields) |field| {
    //        if (field.field_type != f32) continue;
    //        if (std.mem.eql(u8, field.name, param_name)) return @field(params, field.name);
    //    }
    //    unreachable;
    //}
    fn getParamAsFloat(self: *const ScriptModule, params: Params, param_index: usize) f32 {
        const param_name = self.script.parse_result.modules[self.module_index].params[param_index].name;
        inline for (@typeInfo(Params).Struct.fields) |field| {
            if (field.field_type != f32) continue;
            if (std.mem.eql(u8, field.name, param_name)) return @field(params, field.name);
        }
        unreachable;
    }
    fn getParamAsBool(self: *const ScriptModule, params: Params, param_index: usize) bool {
        const param_name = self.script.parse_result.modules[self.module_index].params[param_index].name;
        inline for (@typeInfo(Params).Struct.fields) |field| {
            if (field.field_type != bool) continue;
            if (std.mem.eql(u8, field.name, param_name)) return @field(params, field.name);
        }
        unreachable;
    }
};
