const std = @import("std");
const Source = @import("tokenize.zig").Source;
const Token = @import("tokenize.zig").Token;
const TokenType = @import("tokenize.zig").TokenType;
const TokenIterator = @import("tokenize.zig").TokenIterator;
const fail = @import("fail.zig").fail;
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
    token_it: TokenIterator,
    modules: std.ArrayList(Module),
};

fn expectParamType(self: *FirstPass) !ParamType {
    const type_token = try self.token_it.expectIdentifier("param type");
    const type_name = self.token_it.getSourceString(type_token.source_range);
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
    return self.token_it.failExpected("param_type", type_token.source_range);
}

fn defineModule(self: *FirstPass) !void {
    const module_name_token = try self.token_it.expectIdentifier("module name");
    const module_name = self.token_it.getSourceString(module_name_token.source_range);
    if (module_name[0] < 'A' or module_name[0] > 'Z') {
        return fail(self.token_it.source, module_name_token.source_range, "module name must start with a capital letter", .{});
    }
    _ = try self.token_it.expectOneOf(&[_]TokenType{.sym_colon});

    var params = std.ArrayList(ModuleParam).init(self.arena_allocator);

    while (true) {
        const token = try self.token_it.expectOneOf(&[_]TokenType{ .kw_begin, .identifier });
        switch (token.tt) {
            else => unreachable,
            .kw_begin => break,
            .identifier => {
                // param declaration
                const param_name = self.token_it.getSourceString(token.source_range);
                if (param_name[0] < 'a' or param_name[0] > 'z') {
                    return fail(self.token_it.source, token.source_range, "param name must start with a lowercase letter", .{});
                }
                for (params.items) |param| {
                    if (std.mem.eql(u8, param.name, param_name)) {
                        return fail(self.token_it.source, token.source_range, "redeclaration of param `<`", .{});
                    }
                }
                _ = try self.token_it.expectOneOf(&[_]TokenType{.sym_colon});
                const param_type = try expectParamType(self);
                _ = try self.token_it.expectOneOf(&[_]TokenType{.sym_comma});
                try params.append(.{
                    .name = param_name,
                    .param_type = param_type,
                });
            },
        }
    }

    // skip paint block
    const begin_token = self.token_it.i;
    var num_inner_blocks: usize = 0; // "delay" ops use inner blocks
    while (true) {
        const token = try self.token_it.expect("`end`");
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
    const end_token = self.token_it.i;

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
        .token_it = TokenIterator.init(source, tokens),
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

    // parse module declarations, including param declarations, but skipping over the paint blocks
    while (self.token_it.next()) |token| {
        switch (token.tt) {
            .kw_def => try defineModule(&self),
            else => return self.token_it.failExpected("`def` or end of file", token.source_range),
        }
    }

    return FirstPassResult{
        .arena = arena,
        .builtin_packages = builtin_packages,
        .modules = self.modules.toOwnedSlice(),
    };
}
