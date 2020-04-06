const std = @import("std");
const Parser = @import("common.zig").Parser;
const Source = @import("common.zig").Source;
const fail = @import("common.zig").fail;
const Token = @import("tokenizer.zig").Token;
const builtins = @import("builtins.zig").builtins;

pub const ParamTypeEnum = struct {
    zig_name: []const u8,
    values: []const []const u8,
};

pub const ParamType = union(enum) {
    boolean,
    buffer,
    constant,

    // script modules are disallowed from using this one, for now. only builtins can use it.
    // implementing this would require generating (in zig) a separate copy of the paint method
    // for every combination of params being constant or buffer (so if there were 3 constant-
    // or-buffer params, there would be 2^3 = 8 paint methods).
    // that's going to be a pain, so forget about it for now.
    constant_or_buffer,

    // script modules also cannot use this
    one_of: ParamTypeEnum,
};

pub const ModuleParam = struct {
    name: []const u8,
    type_token: ?Token, // null if this comes from a builtin module
    param_type: ParamType,
};

pub const ModuleField = struct {
    name: []const u8,
    type_name: []const u8,
    type_token: Token,
    resolved_module_index: usize,
};

pub const Module = struct {
    name: []const u8,
    zig_name: []const u8,
    first_param: usize,
    num_params: usize,
    first_field: usize,
    num_fields: usize,
};

pub const ModuleBodyLocation = struct {
    begin_token: usize,
    end_token: usize,
};

const FirstPass = struct {
    allocator: *std.mem.Allocator,
    parser: Parser,
    modules: std.ArrayList(Module),
    module_body_locations: std.ArrayList(?ModuleBodyLocation),
    module_params: std.ArrayList(ModuleParam),
    module_fields: std.ArrayList(ModuleField),
};

fn defineModule(self: *FirstPass) !void {
    const module_name = try self.parser.expectIdentifier();

    const ctoken = try self.parser.expect();
    if (ctoken.tt != .sym_colon) {
        return fail(self.parser.source, ctoken.source_range, "expected `:`, found `%`", .{ctoken.source_range});
    }

    var params = std.ArrayList(ModuleParam).init(self.allocator);
    errdefer params.deinit();
    var fields = std.ArrayList(ModuleField).init(self.allocator);
    errdefer fields.deinit();

    while (true) {
        var token = try self.parser.expect();
        switch (token.tt) {
            .kw_begin => break,
            .kw_param => {
                // param declaration
                const field_name = try self.parser.expectIdentifier();
                const type_token = try self.parser.expect();
                if (type_token.tt != .identifier) {
                    //.identifier => self.parser.source.contents[type_token.source_range.loc0.index..type_token.source_range.loc1.index],
                    return fail(self.parser.source, type_token.source_range, "expected param type, found `%`", .{type_token.source_range});
                }
                token = try self.parser.expect();
                if (token.tt != .sym_semicolon) {
                    return fail(self.parser.source, token.source_range, "expected `;`, found `%`", .{token.source_range});
                }
                try params.append(.{
                    .name = field_name,
                    .type_token = type_token,
                    .param_type = undefined, // will be set before we finish the first pass
                });
            },
            .identifier => {
                // field declaration
                const field_name = self.parser.source.contents[token.source_range.loc0.index..token.source_range.loc1.index];
                const type_token = try self.parser.expect();
                const type_name = switch (type_token.tt) {
                    .identifier => self.parser.source.contents[type_token.source_range.loc0.index..type_token.source_range.loc1.index],
                    else => return fail(self.parser.source, type_token.source_range, "expected field type, found `%`", .{type_token.source_range}),
                };
                const ctoken2 = try self.parser.expect();
                if (ctoken2.tt != .sym_semicolon) {
                    return fail(self.parser.source, ctoken2.source_range, "expected `;`, found `%`", .{ctoken2.source_range});
                }
                try fields.append(.{
                    .name = field_name,
                    .type_token = type_token,
                    .type_name = type_name,
                    .resolved_module_index = undefined, // will be set before we finish the first pass
                });
            },
            else => {
                return fail(self.parser.source, token.source_range, "expected field declaration or `begin`, found `%`", .{token.source_range});
            },
        }
    }

    // skip paint block
    const begin_token = self.parser.i;
    var num_inner_blocks: usize = 0; // "delay" ops use inner blocks
    while (true) {
        const token = try self.parser.expect();
        switch (token.tt) {
            .kw_begin => num_inner_blocks += 1,
            .kw_end => {
                if (num_inner_blocks == 0) {
                    break;
                }
                num_inner_blocks -= 1;
            },
            else => {},
        }
    }
    const end_token = self.parser.i;

    try self.modules.append(.{
        .name = module_name,
        .zig_name = module_name,
        .first_param = self.module_params.len,
        .num_params = params.len,
        .first_field = self.module_fields.len,
        .num_fields = fields.len,
    });
    try self.module_body_locations.append(ModuleBodyLocation{
        .begin_token = begin_token,
        .end_token = end_token,
    });
    try self.module_params.appendSlice(params.toOwnedSlice());
    try self.module_fields.appendSlice(fields.toOwnedSlice());
}

pub const FirstPassResult = struct {
    modules: []const Module,
    module_body_locations: []const ?ModuleBodyLocation,
    module_params: []const ModuleParam,
    module_fields: []const ModuleField,
};

pub fn firstPass(source: Source, tokens: []const Token, allocator: *std.mem.Allocator) !FirstPassResult {
    var self: FirstPass = .{
        .allocator = allocator,
        .parser = .{
            .source = source,
            .tokens = tokens,
            .i = 0,
        },
        .modules = std.ArrayList(Module).init(allocator),
        .module_body_locations = std.ArrayList(?ModuleBodyLocation).init(allocator),
        .module_params = std.ArrayList(ModuleParam).init(allocator),
        .module_fields = std.ArrayList(ModuleField).init(allocator),
    };

    // add builtins
    for (builtins) |builtin| {
        try self.modules.append(.{
            .name = builtin.name,
            .zig_name = builtin.zig_name,
            .first_param = self.module_params.len,
            .num_params = builtin.params.len,
            .first_field = 0,
            .num_fields = 0,
        });
        try self.module_body_locations.append(null);
        try self.module_params.appendSlice(builtin.params);
    }

    // TODO this should be defer, not errdefer, since we are reallocating everything for the FirstPassResult
    //errdefer {
    //    // FIXME deinit fields
    //    self.module_defs.deinit();
    //}

    // parse module declarations, including param and field declarations, but skipping over the painting functions
    while (self.parser.next()) |token| {
        switch (token.tt) {
            .kw_def => try defineModule(&self),
            else => return fail(self.parser.source, token.source_range, "expected `def` or end of file, found `%`", .{token.source_range}),
        }
    }

    const modules = self.modules.toOwnedSlice();
    const module_body_locations = self.module_body_locations.toOwnedSlice();
    const module_params = self.module_params.toOwnedSlice();
    const module_fields = self.module_fields.toOwnedSlice();

    // resolve the types of params and fields
    try resolveParamTypes(source, modules, module_params);
    try resolveFieldTypes(source, modules, module_fields);

    return FirstPassResult{
        .modules = modules,
        .module_body_locations = module_body_locations,
        .module_params = module_params,
        .module_fields = module_fields,
    };
}

// this is the 1 1/2 pass - resolving the types of params and fields.

const DataType = union(enum) {
    param_type: ParamType,
    module_index: usize,
};

fn parseDataType(source: Source, modules: []const Module, type_token: Token) !DataType {
    const type_name = source.contents[type_token.source_range.loc0.index..type_token.source_range.loc1.index];
    if (std.mem.eql(u8, type_name, "boolean")) {
        return DataType{ .param_type = .boolean };
    }
    if (std.mem.eql(u8, type_name, "constant")) {
        return DataType{ .param_type = .constant };
    }
    if (std.mem.eql(u8, type_name, "waveform")) {
        return DataType{ .param_type = .buffer };
    }
    // for now, script modules are not allowed to have ConstantOrBuffer params (the codegen of those is going
    // to be tricky, see my comment in the ParamType enum).
    for (modules) |module, i| {
        if (std.mem.eql(u8, type_name, module.name)) {
            return DataType{ .module_index = i };
        }
    }
    return fail(source, type_token.source_range, "expected datatype, found `%`", .{type_token.source_range});
}

fn resolveParamTypes(source: Source, modules: []const Module, module_params: []ModuleParam) !void {
    // loop over the global list of params
    for (module_params) |*param| {
        const type_token = param.type_token orelse continue; // skip builtin modules which are already resolved
        const datatype = try parseDataType(source, modules, type_token);
        param.param_type = switch (datatype) {
            .param_type => |param_type| param_type,
            .module_index => return fail(source, type_token.source_range, "module cannot be used as a param type", .{}),
        };
    }
}

fn resolveFieldTypes(source: Source, modules: []const Module, module_fields: []ModuleField) !void {
    for (modules) |module, module_index| {
        const fields = module_fields[module.first_field .. module.first_field + module.num_fields];

        for (fields) |*field| {
            const datatype = try parseDataType(source, modules, field.type_token);
            field.resolved_module_index = switch (datatype) {
                .param_type => return fail(source, field.type_token.source_range, "field type must refer to a module", .{}),
                .module_index => |i| i,
            };
        }
    }

    // we will check for circular dependencies (through the fields) in the second pass.
}
