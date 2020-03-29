const std = @import("std");
const zang = @import("zang");
const ModuleParam = @import("first_pass.zig").ModuleParam;

pub const BuiltinModule = struct {
    name: []const u8,
    zig_name: []const u8, // prefix with "zang."
    params: []const ModuleParam,
    num_temps: usize,
    num_outputs: usize,
};

fn getBuiltinModule(comptime T: type) BuiltinModule {
    comptime var params: [@typeInfo(T.Params).Struct.fields.len]ModuleParam = undefined;
    inline for (@typeInfo(T.Params).Struct.fields) |field, i| {
        params[i] = .{
            .name = field.name,
            .type_token = null,
            .param_type = switch (field.field_type) {
                bool => .boolean,
                f32 => .constant,
                []const f32 => .buffer,
                zang.ConstantOrBuffer => .constant_or_buffer,
                else => @compileError("unsupported builtin field type: " ++ @typeName(field.field_type)),
            },
        };
    }
    return .{
        .name = @typeName(T),
        .zig_name = "zang." ++ @typeName(T),
        .params = &params,
        .num_temps = T.num_temps,
        .num_outputs = T.num_outputs,
    };
}

pub const builtins = [_]BuiltinModule{
    // zang.Curve
    // zang.Decimator
    // zang.Distortion
    // zang.Envelope
    // zang.Filter
    getBuiltinModule(zang.Gate),
    getBuiltinModule(zang.Noise),
    // zang.Portamento
    getBuiltinModule(zang.PulseOsc),
    // zang.Sampler
    getBuiltinModule(zang.SineOsc),
    getBuiltinModule(zang.TriSawOsc),
};
