const std = @import("std");
const zang = @import("../zang.zig");
const ModuleParam = @import("parse.zig").ModuleParam;
const ParamType = @import("parse.zig").ParamType;

pub const BuiltinModule = struct {
    name: []const u8,
    params: []const ModuleParam,
    num_temps: usize,
    num_outputs: usize,
};

fn getBuiltinParamType(comptime T: type) ParamType {
    switch (@typeInfo(T)) {
        .Enum => |enum_info| {
            comptime var values: [enum_info.fields.len][]const u8 = undefined;
            inline for (enum_info.fields) |field, i| {
                values[i] = field.name;
            }
            return .{
                .one_of = .{
                    // assume it's one of the public enums (e.g. zang.FilterType)
                    .zig_name = "zang." ++ @typeName(T),
                    .values = &values,
                },
            };
        },
        else => return switch (T) {
            bool => .boolean,
            f32 => .constant,
            []const f32 => .buffer,
            zang.ConstantOrBuffer => .constant_or_buffer,
            else => @compileError("unsupported builtin field type: " ++ @typeName(T)),
        },
    }
}

pub fn getBuiltinModule(comptime T: type) BuiltinModule {
    const struct_fields = @typeInfo(T.Params).Struct.fields;
    comptime var params: [struct_fields.len]ModuleParam = undefined;
    inline for (struct_fields) |field, i| {
        params[i] = .{
            .name = field.name,
            .param_type = getBuiltinParamType(field.field_type),
        };
    }
    return .{
        .name = @typeName(T),
        .params = &params,
        .num_temps = T.num_temps,
        .num_outputs = T.num_outputs,
    };
}

pub const BuiltinPackage = struct {
    zig_package_name: []const u8,
    zig_import_path: []const u8,
    builtins: []const BuiltinModule,
};

pub const zang_builtin_package = BuiltinPackage{
    .zig_package_name = "zang",
    .zig_import_path = "zang",
    .builtins = &[_]BuiltinModule{
        // zang.Curve
        getBuiltinModule(zang.Decimator),
        getBuiltinModule(zang.Distortion),
        // zang.Envelope
        getBuiltinModule(zang.Filter),
        getBuiltinModule(zang.Gate),
        getBuiltinModule(zang.Noise),
        // zang.Portamento
        getBuiltinModule(zang.PulseOsc),
        // zang.Sampler
        getBuiltinModule(zang.SineOsc),
        getBuiltinModule(zang.TriSawOsc),
    },
};
