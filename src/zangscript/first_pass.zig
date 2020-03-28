const std = @import("std");
const Parser = @import("common.zig").Parser;
const Source = @import("common.zig").Source;
const fail = @import("common.zig").fail;
const Token = @import("tokenizer.zig").Token;
const builtins = @import("builtins.zig").builtins;

pub const ResolvedParamType = enum {
    boolean,
    constant,
    constant_or_buffer,
};

pub const ModuleParam = struct {
    name: []const u8,
    type_token: ?Token, // null if this comes from a builtin module
    param_type: ResolvedParamType,
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
    while (true) {
        const token = try self.parser.expect();
        switch (token.tt) {
            .kw_end => break,
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
    param_type: ResolvedParamType,
    module_index: usize,
};

fn parseDataType(source: Source, modules: []const Module, type_token: Token) !DataType {
    const type_name = source.contents[type_token.source_range.loc0.index..type_token.source_range.loc1.index];
    if (std.mem.eql(u8, type_name, "boolean")) {
        return DataType{ .param_type = .boolean };
    }
    if (std.mem.eql(u8, type_name, "number")) {
        return DataType{ .param_type = .constant };
    }
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

    // check for circular dependencies.
    // TODO - this may not be necessary here. i have to visit the modules in dependency order
    // in the second pass (because of num_temps), so maybe i should do this check there instead,
    // instead of doing the work in both places
    for (modules) |module, module_index| {
        const fields = module_fields[module.first_field .. module.first_field + module.num_fields];

        for (fields) |field| {
            try checkForCircularDependencies(source, modules, module_fields, module_index, field, field);
        }
    }
}

fn checkForCircularDependencies(source: Source, modules: []const Module, module_fields: []const ModuleField, self_module_index: usize, original_field: ModuleField, field: ModuleField) error{Failed}!void {
    const inner_module_index = field.resolved_module_index;

    if (inner_module_index == self_module_index) {
        return fail(source, original_field.type_token.source_range, "circular dependency in module fields", .{});
    }

    const inner_module = modules[inner_module_index];
    const inner_fields = module_fields[inner_module.first_field .. inner_module.first_field + inner_module.num_fields];

    for (inner_fields) |inner_field| {
        try checkForCircularDependencies(source, modules, module_fields, self_module_index, original_field, inner_field);
    }
}
