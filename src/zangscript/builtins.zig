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

pub const BuiltinEnum = struct {
    name: []const u8,
    zig_name: []const u8,
    values: []const []const u8,
};

fn getBuiltinEnumFromEnumInfo(comptime typeName: []const u8, comptime enum_info: std.builtin.TypeInfo.Enum) BuiltinEnum {
    comptime var values: [enum_info.fields.len][]const u8 = undefined;
    inline for (enum_info.fields) |field, i| {
        values[i] = field.name;
    }
    return .{
        // assume it's one of the public enums (e.g. zang.FilterType)
        .name = typeName,
        .zig_name = "zang." ++ typeName,
        .values = &values,
    };
}

fn getBuiltinEnumFromUnionInfo(comptime typeName: []const u8, comptime union_info: std.builtin.TypeInfo.Union) BuiltinEnum {
    switch (@typeInfo(union_info.tag_type.?)) {
        .Enum => |enum_info| return getBuiltinEnumFromEnumInfo(typeName, enum_info),
        else => unreachable,
    }
}

fn getBuiltinEnum(comptime T: type) BuiltinEnum {
    switch (@typeInfo(T)) {
        .Enum => |enum_info| return getBuiltinEnumFromEnumInfo(@typeName(T), enum_info),
        .Union => |union_info| return getBuiltinEnumFromUnionInfo(@typeName(T), union_info),
        else => @compileError("getBuiltinEnum: not an enum: " ++ @typeName(T)),
    }
}

// this also reads enums, separately from the global list of enums that we get for the builtin package.
// but it's ok because zangscript compares enums "structurally".
// (although i don't think zig does. so this might create zig errors if i try to codegen something
// that uses enums with overlapping value names. not important now though because user-defined enums
// are currently not supported, and so far no builtins have overlapping enums)
fn getBuiltinParamType(comptime T: type) ParamType {
    return switch (T) {
        bool => .boolean,
        f32 => .constant,
        []const f32 => .buffer,
        zang.ConstantOrBuffer => .constant_or_buffer,
        else => switch (@typeInfo(T)) {
            .Enum => |enum_info| return .{ .one_of = getBuiltinEnumFromEnumInfo(@typeName(T), enum_info) },
            .Union => |union_info| return .{ .one_of = getBuiltinEnumFromUnionInfo(@typeName(T), union_info) },
            else => @compileError("unsupported builtin field type: " ++ @typeName(T)),
        },
    };
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
    enums: []const BuiltinEnum,
};

pub const zang_builtin_package = BuiltinPackage{
    .zig_package_name = "zang",
    .zig_import_path = "zang",
    .builtins = &[_]BuiltinModule{
        // zang.Curve
        getBuiltinModule(zang.Decimator),
        getBuiltinModule(zang.Distortion),
        getBuiltinModule(zang.Envelope),
        getBuiltinModule(zang.Filter),
        getBuiltinModule(zang.Gate),
        getBuiltinModule(zang.Noise),
        // zang.Portamento
        getBuiltinModule(zang.PulseOsc),
        // zang.Sampler
        getBuiltinModule(zang.SineOsc),
        getBuiltinModule(zang.TriSawOsc),
    },
    .enums = &[_]BuiltinEnum{
        getBuiltinEnum(zang.DistortionType),
        getBuiltinEnum(zang.FilterType),
        getBuiltinEnum(zang.Painter.Curve),
    },
};
