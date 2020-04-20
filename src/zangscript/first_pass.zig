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

    // currently only builtin modules can define enum params
    one_of: ParamTypeEnum,
};

pub const ModuleParam = struct {
    name: []const u8,
    param_type: ParamType,
};

pub const Module = struct {
    name: []const u8,
    zig_package_name: ?[]const u8, // only set for builtin modules
    params: []const ModuleParam,
    // FIXME - i wanted body_loc to be an optional struct value, but a zig
    // compiler bug prevents that. (if i make it optional, the fields will read
    // out as all 0's in the second pass)
    has_body_loc: bool,
    // the following will both be zero for builtin modules (has_body_loc is
    // false)
    begin_token: usize,
    end_token: usize,
};

const FirstPass = struct {
    arena_allocator: *std.mem.Allocator,
    parser: Parser,
    modules: std.ArrayList(Module),
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

    var params = std.ArrayList(ModuleParam).init(self.arena_allocator);

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
                for (params.items) |param| {
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
        .params = params.toOwnedSlice(),
        .has_body_loc = true,
        .begin_token = begin_token,
        .end_token = end_token,
    });
}

pub const FirstPassResult = struct {
    arena: std.heap.ArenaAllocator,
    builtin_packages: []const BuiltinPackage,
    modules: []const Module,

    pub fn deinit(self: *FirstPassResult) void {
        self.arena.deinit();
    }
};

pub fn firstPass(source: Source, tokens: []const Token, builtin_packages: []const BuiltinPackage, inner_allocator: *std.mem.Allocator) !FirstPassResult {
    var arena = std.heap.ArenaAllocator.init(inner_allocator);
    errdefer arena.deinit();

    var self: FirstPass = .{
        .arena_allocator = &arena.allocator,
        .parser = .{
            .source = source,
            .tokens = tokens,
            .i = 0,
        },
        .modules = std.ArrayList(Module).init(&arena.allocator),
    };

    // add builtins
    for (builtin_packages) |pkg| {
        for (pkg.builtins) |builtin| {
            try self.modules.append(.{
                .name = builtin.name,
                .zig_package_name = pkg.zig_package_name,
                .params = builtin.params,
                .has_body_loc = false,
                .begin_token = 0,
                .end_token = 0,
            });
        }
    }

    // parse module declarations, including param and field declarations, but skipping over the painting functions
    while (self.parser.next()) |token| {
        switch (token.tt) {
            .kw_def => try defineModule(&self),
            else => return fail(self.parser.source, token.source_range, "expected `def` or end of file, found `<`", .{}),
        }
    }

    return FirstPassResult{
        .arena = arena,
        .builtin_packages = builtin_packages,
        .modules = self.modules.toOwnedSlice(),
    };
}
