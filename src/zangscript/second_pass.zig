const std = @import("std");
const zang = @import("zang");
const Parser = @import("common.zig").Parser;
const Source = @import("common.zig").Source;
const fail = @import("common.zig").fail;
const Token = @import("tokenizer.zig").Token;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const tokenize = @import("tokenizer.zig").tokenize;
const ModuleDef = @import("first_pass.zig").ModuleDef;
const ModuleFieldDecl = @import("first_pass.zig").ModuleFieldDecl;
const ModuleParam = @import("first_pass.zig").ModuleParam;
const ResolvedParamType = @import("first_pass.zig").ResolvedParamType;
const codegen = @import("codegen.zig").codegen;

pub const CallArg = struct {
    arg_name: []const u8,
    value: *const Expression,
};

pub const Call = struct {
    field_index: usize, // index of the field in the "self" module
    args: std.ArrayList(CallArg),
};

pub const Expression = union(enum) {
    call: Call,
    literal: Literal,
    // TODO param_value
    nothing,
};

pub const Literal = union(ResolvedParamType) {
    boolean: bool,
    constant: f32,
    constant_or_buffer: void, // not allowed
};

const ParseError = error{
    Failed,
    OutOfMemory,
};

fn getExpressionType(expression: *const Expression) ResolvedParamType {
    switch (expression.*) {
        .call => |call| {
            return .constant_or_buffer; // FIXME?
        },
        .literal => |literal| {
            return literal;
        },
        .nothing => {
            unreachable;
        },
    }
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
    allocator: *std.mem.Allocator,
) ParseError!CallArg {
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
            const token3 = try p.expect();
            const subexpr = try parseExpression(p, module_defs, self, token3, allocator);
            // type check!
            const subexpr_type = getExpressionType(subexpr);
            switch (param_type) {
                .boolean => {
                    if (subexpr_type != .boolean) {
                        return fail(p.source, token3, "type mismatch (expecting boolean)", .{});
                    }
                },
                .constant => {
                    if (subexpr_type != .constant) {
                        return fail(p.source, token3, "type mismatch (expecting constant)", .{});
                    }
                },
                .constant_or_buffer => {
                    // constant will coerce to constant_or_buffer
                    if (subexpr_type != .constant and subexpr_type != .constant_or_buffer) {
                        return fail(p.source, token3, "type mismatch (expecting number)", .{});
                    }
                },
            }
            return CallArg{
                .arg_name = identifier,
                .value = subexpr,
            };
        },
        else => {
            return fail(p.source, token, "expected `)` or arg name, found `%`", .{token});
        },
    }
}

fn parseCall(self: *Parser, module_defs: []const ModuleDef, module_def: *ModuleDef, allocator: *std.mem.Allocator) ParseError!Call {
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
    const params = field.resolved_module.params;
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
        const arg = try parseCallArg(self, token, module_defs, module_def, params, field, allocator);
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

fn parseExpression(
    parser: *Parser,
    module_defs: []const ModuleDef,
    module_def: *ModuleDef,
    token: Token,
    allocator: *std.mem.Allocator,
) ParseError!*const Expression {
    switch (token.tt) {
        .kw_false => {
            const expr = try allocator.create(Expression);
            expr.* = .{ .literal = .{ .boolean = false } };
            return expr;
        },
        .kw_true => {
            const expr = try allocator.create(Expression);
            expr.* = .{ .literal = .{ .boolean = true } };
            return expr;
        },
        .number => |n| {
            const expr = try allocator.create(Expression);
            expr.* = .{ .literal = .{ .constant = n } };
            return expr;
        },
        .sym_at => {
            const expr = try allocator.create(Expression);
            expr.* = Expression{ .call = try parseCall(parser, module_defs, module_def, allocator) };
            return expr;
        },
        else => {
            //return fail(source, token, "expected `@` or `end`, found `%`", .{token});
            return fail(parser.source, token, "expected expression, found `%`", .{token});
        },
    }
}

fn paintBlock(
    source: Source,
    tokens: []const Token,
    module_defs: []ModuleDef,
    module_def: *ModuleDef,
    allocator: *std.mem.Allocator,
) !*const Expression {
    var parser: Parser = .{
        .source = source,
        .tokens = tokens[module_def.begin_token..module_def.end_token],
        .i = 0,
    };
    while (true) {
        const token = try parser.expect();
        if (token.tt == .kw_end) {
            break;
        }
        return try parseExpression(&parser, module_defs, module_def, token, allocator);
    }
    const expr = try allocator.create(Expression);
    expr.* = .nothing;
    return expr;
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
            std.debug.warn("    field {}: {}\n", .{ field.name, field.type_name });
        }
        std.debug.warn("print expression:\n", .{});
        printExpression(module_defs, module_def, module_def.expression, 1);

        try codegen(module_def, module_def.expression, allocator);
    }
}

fn printExpression(module_defs: []const ModuleDef, module_def: *const ModuleDef, expression: *const Expression, indentation: usize) void {
    var i: usize = 0;
    while (i < indentation) : (i += 1) {
        std.debug.warn("    ", .{});
    }
    switch (expression.*) {
        .call => |call| {
            std.debug.warn("call self.{} (\n", .{module_def.fields.span()[call.field_index].name});
            for (call.args.span()) |arg, j| {
                i = 0;
                while (i < indentation + 1) : (i += 1) {
                    std.debug.warn("    ", .{});
                }
                std.debug.warn("{}:\n", .{arg.arg_name});
                printExpression(module_defs, module_def, arg.value, indentation + 2);
                std.debug.warn(",\n", .{});
            }
            i = 0;
            while (i < indentation) : (i += 1) {
                std.debug.warn("    ", .{});
            }
            std.debug.warn(")\n", .{});
        },
        .literal => |literal| {
            switch (literal) {
                .boolean => |v| std.debug.warn("{}", .{v}),
                .constant => |v| std.debug.warn("{d}", .{v}),
                .constant_or_buffer => unreachable,
            }
        },
        .nothing => {
            std.debug.warn("(nothing)\n", .{});
        },
    }
}
