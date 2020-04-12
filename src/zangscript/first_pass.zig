const std = @import("std");
const Parser = @import("common.zig").Parser;
const Source = @import("common.zig").Source;
const fail = @import("common.zig").fail;
const Token = @import("tokenizer.zig").Token;
const BuiltinPackage = @import("builtins.zig").BuiltinPackage;

pub const ParamTypeEnum = struct {
    zig_name: []const u8,
    values: []const []const u8,
};

pub const ParamType = union(enum) {
    boolean,
    buffer,
    constant,
    constant_or_buffer,

    // script modules cannot use this
    one_of: ParamTypeEnum,
};

pub const ModuleParam = struct {
    name: []const u8,
    zig_name: []const u8,
    param_type: ParamType,
};

pub const Module = struct {
    name: []const u8,
    zig_package_name: ?[]const u8, // only set for builtin modules
    first_param: usize,
    num_params: usize,
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
};

fn parseParamType(source: Source, type_token: Token) !ParamType {
    const type_name = source.contents[type_token.source_range.loc0.index..type_token.source_range.loc1.index];
    if (std.mem.eql(u8, type_name, "boolean")) {
        return .boolean;
    }
    if (std.mem.eql(u8, type_name, "constant")) {
        return .constant;
    }
    if (std.mem.eql(u8, type_name, "waveform")) {
        return .buffer;
    }
    if (std.mem.eql(u8, type_name, "cob")) {
        return .constant_or_buffer;
    }
    return fail(source, type_token.source_range, "expected datatype, found `<`", .{});
}

fn defineModule(self: *FirstPass) !void {
    const module_name_token = try self.parser.expect();
    if (module_name_token.tt != .identifier) {
        return fail(self.parser.source, module_name_token.source_range, "expected identifier, found `<`", .{});
    }
    const module_name = self.parser.source.contents[module_name_token.source_range.loc0.index..module_name_token.source_range.loc1.index];
    if (module_name[0] < 'A' or module_name[0] > 'Z') {
        return fail(self.parser.source, module_name_token.source_range, "module name must start with a capital letter", .{});
    }

    const ctoken = try self.parser.expect();
    if (ctoken.tt != .sym_colon) {
        return fail(self.parser.source, ctoken.source_range, "expected `:`, found `<`", .{});
    }

    var params = std.ArrayList(ModuleParam).init(self.allocator);
    errdefer params.deinit();

    while (true) {
        var token = try self.parser.expect();
        switch (token.tt) {
            .kw_begin => break,
            .identifier => {
                // param declaration
                const param_name = self.parser.source.contents[token.source_range.loc0.index..token.source_range.loc1.index];
                if (param_name[0] < 'a' or param_name[0] > 'z') {
                    return fail(self.parser.source, token.source_range, "param name must start with a lowercase letter", .{});
                }
                for (params.span()) |param| {
                    if (std.mem.eql(u8, param.name, param_name)) {
                        return fail(self.parser.source, token.source_range, "redeclaration of param `<`", .{});
                    }
                }
                const colon_token = try self.parser.expect();
                if (colon_token.tt != .sym_colon) {
                    return fail(self.parser.source, colon_token.source_range, "expected `:`, found `<`", .{});
                }
                const type_token = try self.parser.expect();
                if (type_token.tt != .identifier) {
                    return fail(self.parser.source, type_token.source_range, "expected param type, found `<`", .{});
                }
                const param_type = try parseParamType(self.parser.source, type_token);
                token = try self.parser.expect();
                if (token.tt != .sym_comma) {
                    return fail(self.parser.source, token.source_range, "expected `,`, found `<`", .{});
                }
                try params.append(.{
                    .name = param_name,
                    .zig_name = param_name, // TODO wrap zig keywords in `@"..."`?
                    .param_type = param_type,
                });
            },
            else => {
                return fail(self.parser.source, token.source_range, "expected param declaration or `begin`, found `<`", .{});
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
        .zig_package_name = null,
        .first_param = self.module_params.items.len,
        .num_params = params.items.len,
    });
    try self.module_body_locations.append(ModuleBodyLocation{
        .begin_token = begin_token,
        .end_token = end_token,
    });
    try self.module_params.appendSlice(params.toOwnedSlice());
}

pub const FirstPassResult = struct {
    builtin_packages: []const BuiltinPackage,
    modules: []const Module,
    module_body_locations: []const ?ModuleBodyLocation,
    module_params: []const ModuleParam,
};

pub fn firstPass(source: Source, tokens: []const Token, builtin_packages: []const BuiltinPackage, allocator: *std.mem.Allocator) !FirstPassResult {
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
    };

    // add builtins
    for (builtin_packages) |pkg| {
        for (pkg.builtins) |builtin| {
            try self.modules.append(.{
                .name = builtin.name,
                .zig_package_name = pkg.zig_package_name,
                .first_param = self.module_params.items.len,
                .num_params = builtin.params.len,
            });
            try self.module_body_locations.append(null);
            try self.module_params.appendSlice(builtin.params);
        }
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
            else => return fail(self.parser.source, token.source_range, "expected `def` or end of file, found `<`", .{}),
        }
    }

    return FirstPassResult{
        .builtin_packages = builtin_packages,
        .modules = self.modules.toOwnedSlice(),
        .module_body_locations = self.module_body_locations.toOwnedSlice(),
        .module_params = self.module_params.toOwnedSlice(),
    };
}
