const std = @import("std");
const zang = @import("zang");
const Parser = @import("common.zig").Parser;
const Source = @import("common.zig").Source;
const fail = @import("common.zig").fail;
const Token = @import("tokenizer.zig").Token;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const tokenize = @import("tokenizer.zig").tokenize;
const BuiltinModule = @import("first_pass.zig").BuiltinModule;
const ModuleDef = @import("first_pass.zig").ModuleDef;
const ModuleFieldDecl = @import("first_pass.zig").ModuleFieldDecl;
const ModuleParam = @import("first_pass.zig").ModuleParam;
const ResolvedParamType = @import("first_pass.zig").ResolvedParamType;

pub const CallArg = struct {
    arg_name: []const u8,
    value: ?f32,
};
// this will be a lisp like syntax tree... stuff like order of operations will be applied before we get in here
// then an additional pass will be made to bake this down and get temps
pub const Call = struct {
    field_index: usize, // index of the field in the "self" module
    args: std.ArrayList(CallArg),
};

pub const Expression = union(enum) {
    call: Call,
    nothing,
};

fn getBuiltinModuleParams2(comptime T: type) []const ModuleParam {
    comptime var params: [@typeInfo(T.Params).Struct.fields.len]ModuleParam = undefined;
    inline for (@typeInfo(T.Params).Struct.fields) |field, i| {
        params[i] = .{
            .name = field.name,
            .param_type = switch (field.field_type) {
                bool => ResolvedParamType.boolean,
                f32, zang.ConstantOrBuffer => ResolvedParamType.number,
                else => unreachable,
            },
        };
    }
    return &params;
}

fn getBuiltinModuleParams(bmod: BuiltinModule) []const ModuleParam {
    return switch (bmod) {
        .pulse_osc => getBuiltinModuleParams2(zang.PulseOsc),
        .tri_saw_osc => getBuiltinModuleParams2(zang.TriSawOsc),
    };
}

const Literal = struct {
    value_type: ResolvedParamType,
    value: f32, // FIXME
};

fn parseLiteral(p: *Parser) !Literal {
    const token = try p.expect();
    return switch (token.tt) {
        .kw_false => Literal{ .value_type = .boolean, .value = 0 }, // FIXME
        .kw_true => Literal{ .value_type = .boolean, .value = 1 }, // FIXME
        .number => |n| Literal{ .value_type = .number, .value = n },
        else => fail(p.source, token, "expected arg value, found `%`", .{token}),
    };
}

// `module_def` is the module we're in (the "self").
// we also need to know the module type of what we're calling, so we can look up its params
fn parseCallArg(
    p: *Parser,
    token: Token,
    module_defs: []const ModuleDef,
    self: *ModuleDef,
    params: []const ModuleParam,
    field: *const ModuleFieldDecl,
) !CallArg {
    switch (token.tt) {
        .identifier => |identifier| {
            // find this param
            var param_index: usize = undefined;
            for (params) |param, i| {
                if (std.mem.eql(u8, param.name, identifier)) {
                    param_index = i;
                    break;
                }
            } else {
                return fail(p.source, token, "module has no param called `%`", .{token}); // TODO better message
            }
            const param_type = params[param_index].param_type;

            const token2 = try p.expect();
            if (token2.tt != .sym_colon) {
                return fail(p.source, token2, "expected `:`, found `%`", .{token2});
            }
            // currently just looking for a literal value. later should support putting own fields through, more calls, and arithmetic expressions
            const literal = try parseLiteral(p);
            if (literal.value_type != param_type) {
                return fail(p.source, token2, "type mismatch", .{}); // TODO better message
            }
            return CallArg{ .arg_name = identifier, .value = literal.value };
        },
        else => {
            return fail(p.source, token, "expected `)` or arg name, found `%`", .{token});
        },
    }
}

fn parseCall(self: *Parser, module_defs: []const ModuleDef, module_def: *ModuleDef, allocator: *std.mem.Allocator) !Call {
    // referencing one of the fields. like a function call
    const name_token = try self.expect();
    const name = switch (name_token.tt) {
        .identifier => |identifier| identifier,
        else => return fail(self.source, name_token, "expected field name, found `%`", .{name_token}),
    };
    const field_index = for (module_def.fields.span()) |*field, i| {
        if (std.mem.eql(u8, field.name, name)) {
            break i;
        }
    } else {
        //return fail(self.source, name_token, "not a field of `#`: `%`", .{ module_def.name, name_token }); // FIXME not working?
        return fail(self.source, name_token, "not a field of self: `%`", .{name_token});
    };
    // arguments
    const field = &module_def.fields.span()[field_index];
    const params = switch (field.resolved_type) {
        .builtin_module => |bmod| getBuiltinModuleParams(bmod),
        .script_module => |module_index| module_defs[module_index].params,
    };
    var token = try self.expect();
    if (token.tt != .sym_left_paren) {
        return fail(self.source, token, "expected `(`, found `%`", .{token});
    }
    var args = std.ArrayList(CallArg).init(allocator);
    errdefer args.deinit();
    var first = true;
    while (true) {
        token = try self.expect();
        if (token.tt == .sym_right_paren) {
            break;
        }
        if (first) {
            first = false;
        } else {
            if (token.tt == .sym_comma) {
                token = try self.expect();
            } else {
                return fail(self.source, token, "expected `,` or `)`, found `%`", .{token});
            }
        }
        const arg = try parseCallArg(self, token, module_defs, module_def, params, field);
        try args.append(arg);
    }
    // make sure all args are accounted for
    for (params) |param| {
        var found = false;
        for (args.span()) |arg| {
            if (std.mem.eql(u8, arg.arg_name, param.name)) {
                found = true;
            }
        }
        if (!found) {
            return fail(self.source, token, "call is missing param `#`", .{param.name}); // TODO improve message
        }
    }
    return Call{
        .field_index = field_index,
        .args = args,
    };
}

fn paintBlock(
    source: Source,
    tokens: []const Token,
    module_defs: []ModuleDef,
    module_def: *ModuleDef,
    allocator: *std.mem.Allocator,
) !Expression {
    var self: Parser = .{
        .source = source,
        .tokens = tokens[module_def.begin_token..module_def.end_token],
        .i = 0,
    };
    while (true) {
        const token = try self.expect();
        switch (token.tt) {
            .kw_end => break,
            .sym_at => return Expression{ .call = try parseCall(&self, module_defs, module_def, allocator) },
            else => return fail(source, token, "expected `@` or `end`, found `%`", .{token}),
        }
    }
    return Expression.nothing;
}

pub fn secondPass(
    source: Source,
    tokens: []const Token,
    module_defs: []ModuleDef,
    allocator: *std.mem.Allocator,
) !void {
    for (module_defs) |*module_def| {
        module_def.expression = try paintBlock(source, tokens, module_defs, module_def, allocator);

        std.debug.warn("module '{}'\n", .{module_def.name});
        for (module_def.fields.span()) |field| {
            std.debug.warn("field {}: {}\n", .{ field.name, field.type_name });
        }
        printExpression(&module_def.expression);
        std.debug.warn("\n", .{});
    }
}

fn printExpression(expression: *const Expression) void {
    switch (expression.*) {
        .call => |call| {
            std.debug.warn("call {} (", .{call.field_index});
            for (call.args.span()) |arg, i| {
                if (i > 0) std.debug.warn(", ", .{});
                std.debug.warn("{}={}", .{ arg.arg_name, arg.value });
            }
            std.debug.warn(")\n", .{});
        },
        .nothing => {
            std.debug.warn("(nothing)\n", .{});
        },
    }
}
