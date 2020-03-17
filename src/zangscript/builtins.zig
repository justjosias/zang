const std = @import("std");
const zang = @import("zang");
const ModuleParam = @import("first_pass.zig").ModuleParam;

// this is used for both builtin modules and script modules
pub const Module = struct {
    name: []const u8,
    zig_name: []const u8, // prefix with "zang." if it's a builtin
    params: []const ModuleParam,
    num_temps: usize,
    num_outputs: usize,
};

fn getBuiltinModule(comptime T: type) Module {
    var params: [@typeInfo(T.Params).Struct.fields.len]ModuleParam = undefined;
    for (@typeInfo(T.Params).Struct.fields) |field, i| {
        params[i] = .{
            .name = field.name,
            .param_type = switch (field.field_type) {
                bool => .boolean,
                f32 => .constant,
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

pub const builtins = [_]Module{
    getBuiltinModule(zang.PulseOsc),
    getBuiltinModule(zang.SineOsc),
    getBuiltinModule(zang.TriSawOsc),
};

pub fn findBuiltin(name: []const u8) ?*const Module {
    for (builtins) |*builtin| {
        if (std.mem.eql(u8, builtin.name, name)) {
            return builtin;
        }
    }
    return null;
}
