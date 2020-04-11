const std = @import("std");
const zang = @import("zang");
const ModuleParam = @import("first_pass.zig").ModuleParam;
const ParamTypeEnum = @import("first_pass.zig").ParamTypeEnum;

pub const BuiltinModule = struct {
    name: []const u8,
    params: []const ModuleParam,
    num_temps: usize,
    num_outputs: usize,
};

fn getBuiltinEnum(comptime T: type) ParamTypeEnum {
    comptime var values: [@typeInfo(T).Enum.fields.len][]const u8 = undefined;
    inline for (@typeInfo(T).Enum.fields) |field, i| {
        values[i] = field.name;
    }
    return .{
        .zig_name = "zang." ++ @typeName(T), // FIXME?
        .values = &values,
    };
}

fn getBuiltinModule(comptime T: type) BuiltinModule {
    comptime var params: [@typeInfo(T.Params).Struct.fields.len]ModuleParam = undefined;
    inline for (@typeInfo(T.Params).Struct.fields) |field, i| {
        params[i] = .{
            .name =
                // FIXME - remove this.
                if (std.mem.eql(u8, field.name, "filter_type") or std.mem.eql(u8, field.name, "distortion_type"))
                    "type"
                else if (std.mem.eql(u8, field.name, "resonance"))
                    "res"
                else
                    field.name,
            .zig_name = field.name, // FIXME remove this too
            .param_type = switch (field.field_type) {
                bool => .boolean,
                f32 => .constant,
                []const f32 => .buffer,
                zang.ConstantOrBuffer => .constant_or_buffer,
                zang.DistortionType, zang.FilterType => .{ .one_of = getBuiltinEnum(field.field_type) },
                else => @compileError("unsupported builtin field type: " ++ @typeName(field.field_type)),
            },
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
