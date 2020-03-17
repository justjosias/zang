const std = @import("std");
const zang = @import("zang");
const Parser = @import("common.zig").Parser;
const Source = @import("common.zig").Source;
const SourceRange = @import("common.zig").SourceRange;
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

pub const BinaryArithmetic = struct {
    operator: enum { add, multiply },
    a: *const Expression,
    b: *const Expression,
};

pub const ExpressionInner = union(enum) {
    call: Call,
    literal: Literal,
    self_param: usize,
    binary_arithmetic: BinaryArithmetic,
    nothing,
};

pub const Expression = struct {
    source_range: SourceRange,
    inner: ExpressionInner,
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

pub fn getExpressionType(module_def: *const ModuleDef, expression: *const Expression) ResolvedParamType {
    switch (expression.inner) {
        .call => |call| {
            return .constant_or_buffer; // FIXME?
        },
        .literal => |literal| {
            return literal;
        },
        .self_param => |param_index| {
            return module_def.resolved.params[param_index].param_type;
        },
        .binary_arithmetic => |x| {
            // in binary math, we support any combination of floats and buffers.
            // if there's at least one buffer operand, the result will also be a buffer
            const a = getExpressionType(module_def, x.a);
            const b = getExpressionType(module_def, x.b);
            if (a == .constant and b == .constant) {
                return .constant;
            }
            if ((a == .constant or a == .constant_or_buffer) and (b == .constant or b == .constant_or_buffer)) {
                return .constant_or_buffer;
            }
            unreachable;
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
        .identifier => {
            const identifier = p.source.contents[token.source_range.loc0.index..token.source_range.loc1.index];
            // find this param
            var param_index: usize = undefined;
            for (params) |param, i| {
                if (std.mem.eql(u8, param.name, identifier)) {
                    param_index = i;
                    break;
                }
            } else {
                return fail(p.source, token.source_range, "module `#` has no param called `%`", .{
                    field.resolved_module.name,
                    token.source_range,
                });
            }
            const param_type = params[param_index].param_type;

            const token2 = try p.expect();
            if (token2.tt != .sym_colon) {
                return fail(p.source, token2.source_range, "expected `:`, found `%`", .{token2.source_range});
            }
            const token3 = try p.expect();
            const subexpr = try parseExpression(p, module_defs, self, token3, allocator);
            // type check!
            // FIXME is this right place to do type checking?
            // it could also be done in codegen. there are pros and cons to both...
            // - typecheck in second_pass
            //     - pro: could generate new AST instructions for things like implicit conversions
            //     - con: both second_pass and codegen have huge instruction sets
            //     - con: codegen still needs a lot of switch statements that will end up with
            //            `else => unreachable` where the types don't match?
            // - typecheck in codegen
            //     - pro: second_pass and its instruction set remains very simple
            //     - con: i have no tokens to use for error messages
            // or, i could keep the second_pass instruction set simple but still typecheck in
            // the second pass. codegen kind of just assumes that it's been done
            const subexpr_type = getExpressionType(self, subexpr);
            switch (param_type) {
                .boolean => {
                    if (subexpr_type != .boolean) {
                        return fail(p.source, token3.source_range, "type mismatch (expecting boolean)", .{});
                    }
                },
                .constant => {
                    if (subexpr_type != .constant) {
                        return fail(p.source, token3.source_range, "type mismatch (expecting constant)", .{});
                    }
                },
                .constant_or_buffer => {
                    // constant will coerce to constant_or_buffer
                    if (subexpr_type != .constant and subexpr_type != .constant_or_buffer) {
                        return fail(p.source, token3.source_range, "type mismatch (expecting number)", .{});
                    }
                },
            }
            return CallArg{
                .arg_name = identifier,
                .value = subexpr,
            };
        },
        else => {
            return fail(p.source, token.source_range, "expected `)` or arg name, found `%`", .{token.source_range});
        },
    }
}

fn parseSelfParam(self: *Parser, module_defs: []const ModuleDef, module_def: *ModuleDef, allocator: *std.mem.Allocator) ParseError!usize {
    const name_token = try self.expect();
    const name = switch (name_token.tt) {
        .identifier => self.source.contents[name_token.source_range.loc0.index..name_token.source_range.loc1.index],
        else => return fail(self.source, name_token.source_range, "expected param name, found `%`", .{name_token.source_range}),
    };
    const param_index = for (module_def.resolved.params) |param, i| {
        if (std.mem.eql(u8, param.name, name)) {
            break i;
        }
    } else return fail(self.source, name_token.source_range, "not a param of self: `%`", .{name_token.source_range});
    // TODO type check?
    return param_index;
}

fn parseCall(self: *Parser, module_defs: []const ModuleDef, module_def: *ModuleDef, allocator: *std.mem.Allocator) ParseError!Call {
    // referencing one of the fields. like a function call
    const name_token = try self.expect();
    const name = switch (name_token.tt) {
        .identifier => self.source.contents[name_token.source_range.loc0.index..name_token.source_range.loc1.index],
        else => return fail(self.source, name_token.source_range, "expected field name, found `%`", .{name_token.source_range}),
    };
    const field_index = for (module_def.fields.span()) |*field, i| {
        if (std.mem.eql(u8, field.name, name)) {
            break i;
        }
    } else {
        return fail(self.source, name_token.source_range, "not a field of `#`: `%`", .{ module_def.name, name_token.source_range });
    };
    // arguments
    const field = &module_def.fields.span()[field_index];
    const params = field.resolved_module.params;
    var token = try self.expect();
    if (token.tt != .sym_left_paren) {
        return fail(self.source, token.source_range, "expected `(`, found `%`", .{token.source_range});
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
                return fail(self.source, token.source_range, "expected `,` or `)`, found `%`", .{token.source_range});
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
            return fail(self.source, token.source_range, "call is missing param `#`", .{param.name}); // TODO improve message
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
            expr.* = .{
                .source_range = token.source_range,
                .inner = .{ .literal = .{ .boolean = false } },
            };
            return expr;
        },
        .kw_true => {
            const expr = try allocator.create(Expression);
            expr.* = .{
                .source_range = token.source_range,
                .inner = .{ .literal = .{ .boolean = true } },
            };
            return expr;
        },
        .number => {
            const n = std.fmt.parseFloat(f32, parser.source.contents[token.source_range.loc0.index..token.source_range.loc1.index]) catch {
                return fail(parser.source, token.source_range, "malformatted number", .{});
            };
            const expr = try allocator.create(Expression);
            expr.* = .{
                .source_range = token.source_range,
                .inner = .{ .literal = .{ .constant = n } },
            };
            return expr;
        },
        .sym_dollar => {
            const expr = try allocator.create(Expression);
            expr.* = .{
                // FIXME! loc should be expanded
                .source_range = token.source_range,
                .inner = .{ .self_param = try parseSelfParam(parser, module_defs, module_def, allocator) },
            };
            return expr;
        },
        .sym_at => {
            const expr = try allocator.create(Expression);
            expr.* = .{
                // FIXME! loc should be expanded
                .source_range = token.source_range,
                .inner = .{ .call = try parseCall(parser, module_defs, module_def, allocator) },
            };
            return expr;
        },
        .sym_plus => {
            const a = try parseExpression(parser, module_defs, module_def, try parser.expect(), allocator);
            const b = try parseExpression(parser, module_defs, module_def, try parser.expect(), allocator);
            const expr = try allocator.create(Expression);
            expr.* = .{
                // FIXME! loc should be expanded
                .source_range = token.source_range,
                .inner = .{
                    .binary_arithmetic = .{
                        .operator = .add,
                        .a = a,
                        .b = b,
                    },
                },
            };
            return expr;
        },
        .sym_asterisk => {
            const a = try parseExpression(parser, module_defs, module_def, try parser.expect(), allocator);
            const b = try parseExpression(parser, module_defs, module_def, try parser.expect(), allocator);
            const expr = try allocator.create(Expression);
            expr.* = .{
                // FIXME! loc should be expanded
                .source_range = token.source_range,
                .inner = .{
                    .binary_arithmetic = .{
                        .operator = .multiply,
                        .a = a,
                        .b = b,
                    },
                },
            };
            return expr;
        },
        else => {
            //return fail(source, token.source_range, "expected `@` or `end`, found `%`", .{token.source_range});
            return fail(parser.source, token.source_range, "expected expression, found `%`", .{token.source_range});
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
    expr.* = .{
        // FIXME
        .source_range = .{
            .loc0 = .{ .line = 0, .index = 0 },
            .loc1 = .{ .line = 0, .index = 0 },
        },
        .inner = .nothing,
    };
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

        try codegen(source, module_def, module_def.expression, allocator);
    }
}

fn printExpression(module_defs: []const ModuleDef, module_def: *const ModuleDef, expression: *const Expression, indentation: usize) void {
    var i: usize = 0;
    while (i < indentation) : (i += 1) {
        std.debug.warn("    ", .{});
    }
    switch (expression.inner) {
        .call => |call| {
            std.debug.warn("call self.{} (\n", .{module_def.fields.span()[call.field_index].name});
            for (call.args.span()) |arg| {
                i = 0;
                while (i < indentation + 1) : (i += 1) {
                    std.debug.warn("    ", .{});
                }
                std.debug.warn("{}:\n", .{arg.arg_name});
                printExpression(module_defs, module_def, arg.value, indentation + 2);
            }
            i = 0;
            while (i < indentation) : (i += 1) {
                std.debug.warn("    ", .{});
            }
            std.debug.warn(")\n", .{});
        },
        .literal => |literal| {
            switch (literal) {
                .boolean => |v| std.debug.warn("{}\n", .{v}),
                .constant => |v| std.debug.warn("{d}\n", .{v}),
                .constant_or_buffer => unreachable,
            }
        },
        .self_param => |param_index| {
            std.debug.warn("${}\n", .{param_index});
        },
        .binary_arithmetic => |m| {
            switch (m.operator) {
                .add => std.debug.warn("add\n", .{}),
                .multiply => std.debug.warn("multiply\n", .{}),
            }
            printExpression(module_defs, module_def, m.a, indentation + 1);
            printExpression(module_defs, module_def, m.b, indentation + 1);
        },
        .nothing => {
            std.debug.warn("(nothing)\n", .{});
        },
    }
}
