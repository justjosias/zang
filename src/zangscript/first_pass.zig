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
    param_type: ParamType,
};

pub const Module = struct {
    name: []const u8,
    zig_name: []const u8,
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
    // for now, script modules are not allowed to have ConstantOrBuffer params (the codegen of those is going
    // to be tricky, see my comment in the ParamType enum).
    return fail(source, type_token.source_range, "expected datatype, found `%`", .{type_token.source_range});
}

fn defineModule(self: *FirstPass) !void {
    const module_name = try self.parser.expectIdentifier();

    const ctoken = try self.parser.expect();
    if (ctoken.tt != .sym_colon) {
        return fail(self.parser.source, ctoken.source_range, "expected `:`, found `%`", .{ctoken.source_range});
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
                const type_token = try self.parser.expect();
                if (type_token.tt != .identifier) {
                    return fail(self.parser.source, type_token.source_range, "expected param type, found `%`", .{type_token.source_range});
                }
                const param_type = try parseParamType(self.parser.source, type_token);
                token = try self.parser.expect();
                if (token.tt != .sym_semicolon) {
                    return fail(self.parser.source, token.source_range, "expected `;`, found `%`", .{token.source_range});
                }
                try params.append(.{
                    .name = param_name,
                    .param_type = param_type,
                });
            },
            else => {
                return fail(self.parser.source, token.source_range, "expected param declaration or `begin`, found `%`", .{token.source_range});
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
    });
    try self.module_body_locations.append(ModuleBodyLocation{
        .begin_token = begin_token,
        .end_token = end_token,
    });
    try self.module_params.appendSlice(params.toOwnedSlice());
}

pub const FirstPassResult = struct {
    modules: []const Module,
    module_body_locations: []const ?ModuleBodyLocation,
    module_params: []const ModuleParam,
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
    };

    // add builtins
    for (builtins) |builtin| {
        try self.modules.append(.{
            .name = builtin.name,
            .zig_name = builtin.zig_name,
            .first_param = self.module_params.len,
            .num_params = builtin.params.len,
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

    return FirstPassResult{
        .modules = self.modules.toOwnedSlice(),
        .module_body_locations = self.module_body_locations.toOwnedSlice(),
        .module_params = self.module_params.toOwnedSlice(),
    };
}
