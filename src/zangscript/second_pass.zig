const std = @import("std");
const Parser = @import("common.zig").Parser;
const Source = @import("common.zig").Source;
const SourceRange = @import("common.zig").SourceRange;
const fail = @import("common.zig").fail;
const Token = @import("tokenizer.zig").Token;
const FirstPassResult = @import("first_pass.zig").FirstPassResult;
const CustomModule = @import("first_pass.zig").CustomModule;
const ModuleField = @import("first_pass.zig").ModuleField;
const ModuleParam = @import("first_pass.zig").ModuleParam;
const ResolvedParamType = @import("first_pass.zig").ResolvedParamType;
const CodeGenResult = @import("codegen.zig").CodeGenResult;
const codegen = @import("codegen.zig").codegen;
const builtins = @import("builtins.zig").builtins;

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

const SecondPass = struct {
    allocator: *std.mem.Allocator,
    tokens: []const Token,
    parser: Parser,
    first_pass_result: FirstPassResult,
    module: CustomModule,
    module_index: usize,
};

// maybe type checking should be a distinct pass, between second_pass and codegen...
pub fn getExpressionType(source: Source, self_params: []const ModuleParam, expression: *const Expression) error{Failed}!ResolvedParamType {
    switch (expression.inner) {
        .call => |call| {
            return .constant_or_buffer; // FIXME?
        },
        .literal => |literal| {
            return literal;
        },
        .self_param => |param_index| {
            return self_params[param_index].param_type;
        },
        .binary_arithmetic => |x| {
            // in binary math, we support any combination of floats and buffers.
            // if there's at least one buffer operand, the result will also be a buffer
            const a = try getExpressionType(source, self_params, x.a);
            const b = try getExpressionType(source, self_params, x.b);
            if (a == .constant and b == .constant) {
                return .constant;
            }
            if ((a == .constant or a == .constant_or_buffer) and (b == .constant or b == .constant_or_buffer)) {
                return .constant_or_buffer;
            }
            switch (x.operator) {
                .add => return fail(source, expression.source_range, "illegal operand types for `+`: `&`, `&`", .{ a, b }),
                .multiply => return fail(source, expression.source_range, "illegal operand types for `*`: `&`, `&`", .{ a, b }),
            }
        },
        .nothing => {
            unreachable;
        },
    }
}

// `module_def` is the module we're in (the "self").
// we also need to know the module type of what we're calling, so we can look up its params
fn parseCallArg(self: *SecondPass, field_name: []const u8, callee_params: []const ModuleParam, token: Token) ParseError!CallArg {
    switch (token.tt) {
        .identifier => {
            const identifier = self.parser.source.contents[token.source_range.loc0.index..token.source_range.loc1.index];
            // find this param
            var param_index: usize = undefined;
            for (callee_params) |param, i| {
                if (std.mem.eql(u8, param.name, identifier)) {
                    param_index = i;
                    break;
                }
            } else {
                return fail(self.parser.source, token.source_range, "module `#` has no param called `%`", .{ field_name, token.source_range });
            }
            const param_type = callee_params[param_index].param_type;

            const token2 = try self.parser.expect();
            if (token2.tt != .sym_colon) {
                return fail(self.parser.source, token2.source_range, "expected `:`, found `%`", .{token2.source_range});
            }
            const token3 = try self.parser.expect();
            const subexpr = try parseExpression(self, token3);
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
            const self_params = self.first_pass_result.module_params[self.module.first_param .. self.module.first_param + self.module.num_params];
            const subexpr_type = try getExpressionType(self.parser.source, self_params, subexpr);
            switch (param_type) {
                .boolean => {
                    if (subexpr_type != .boolean) {
                        return fail(self.parser.source, token3.source_range, "type mismatch (expecting boolean)", .{});
                    }
                },
                .constant => {
                    if (subexpr_type != .constant) {
                        return fail(self.parser.source, token3.source_range, "type mismatch (expecting constant)", .{});
                    }
                },
                .constant_or_buffer => {
                    // constant will coerce to constant_or_buffer
                    if (subexpr_type != .constant and subexpr_type != .constant_or_buffer) {
                        return fail(self.parser.source, token3.source_range, "type mismatch (expecting number)", .{});
                    }
                },
            }
            return CallArg{
                .arg_name = identifier,
                .value = subexpr,
            };
        },
        else => {
            return fail(self.parser.source, token.source_range, "expected `)` or arg name, found `%`", .{token.source_range});
        },
    }
}

fn parseSelfParam(self: *SecondPass) ParseError!usize {
    const name_token = try self.parser.expect();
    const name = switch (name_token.tt) {
        .identifier => self.parser.source.contents[name_token.source_range.loc0.index..name_token.source_range.loc1.index],
        else => return fail(self.parser.source, name_token.source_range, "expected param name, found `%`", .{name_token.source_range}),
    };
    const params = self.first_pass_result.module_params[self.module.first_param .. self.module.first_param + self.module.num_params];
    const param_index = for (params) |param, i| {
        if (std.mem.eql(u8, param.name, name)) {
            break i;
        }
    } else return fail(self.parser.source, name_token.source_range, "not a param of self: `%`", .{name_token.source_range});
    // TODO type check?
    return param_index;
}

fn parseCall(self: *SecondPass) ParseError!Call {
    // referencing one of the fields. like a function call
    const field_name_token = try self.parser.expect();
    const field_name = switch (field_name_token.tt) {
        .identifier => self.parser.source.contents[field_name_token.source_range.loc0.index..field_name_token.source_range.loc1.index],
        else => return fail(self.parser.source, field_name_token.source_range, "expected field name, found `%`", .{field_name_token.source_range}),
    };
    const fields = self.first_pass_result.module_fields[self.module.first_field .. self.module.first_field + self.module.num_fields];
    const field_index = for (fields) |*field, i| {
        if (std.mem.eql(u8, field.name, field_name)) {
            break i;
        }
    } else {
        return fail(self.parser.source, field_name_token.source_range, "not a field of `#`: `%`", .{ self.module.name, field_name_token.source_range });
    };
    const field = self.first_pass_result.module_fields[self.module.first_field + field_index];
    // arguments
    const callee_params = blk: {
        const callee_module = self.first_pass_result.modules[field.resolved_module_index];
        break :blk self.first_pass_result.module_params[callee_module.first_param .. callee_module.first_param + callee_module.num_params];
    };
    var token = try self.parser.expect();
    if (token.tt != .sym_left_paren) {
        return fail(self.parser.source, token.source_range, "expected `(`, found `%`", .{token.source_range});
    }
    var args = std.ArrayList(CallArg).init(self.allocator);
    errdefer args.deinit();
    var first = true;
    while (true) {
        token = try self.parser.expect();
        if (token.tt == .sym_right_paren) {
            break;
        }
        if (first) {
            first = false;
        } else {
            if (token.tt == .sym_comma) {
                token = try self.parser.expect();
            } else {
                return fail(self.parser.source, token.source_range, "expected `,` or `)`, found `%`", .{token.source_range});
            }
        }
        const arg = try parseCallArg(self, field_name, callee_params, token);
        try args.append(arg);
    }
    // make sure all args are accounted for
    for (callee_params) |param| {
        var found = false;
        for (args.span()) |arg| {
            if (std.mem.eql(u8, arg.arg_name, param.name)) {
                found = true;
            }
        }
        if (!found) {
            return fail(self.parser.source, token.source_range, "call is missing param `#`", .{param.name}); // TODO improve message
        }
    }
    return Call{
        .field_index = field_index,
        .args = args, // TODO can i toOwnedSlice here?
    };
}

fn parseExpression(self: *SecondPass, token: Token) ParseError!*const Expression {
    switch (token.tt) {
        .kw_false => {
            const expr = try self.allocator.create(Expression);
            expr.* = .{
                .source_range = token.source_range,
                .inner = .{ .literal = .{ .boolean = false } },
            };
            return expr;
        },
        .kw_true => {
            const expr = try self.allocator.create(Expression);
            expr.* = .{
                .source_range = token.source_range,
                .inner = .{ .literal = .{ .boolean = true } },
            };
            return expr;
        },
        .number => {
            const n = std.fmt.parseFloat(f32, self.parser.source.contents[token.source_range.loc0.index..token.source_range.loc1.index]) catch {
                return fail(self.parser.source, token.source_range, "malformatted number", .{});
            };
            const expr = try self.allocator.create(Expression);
            expr.* = .{
                .source_range = token.source_range,
                .inner = .{ .literal = .{ .constant = n } },
            };
            return expr;
        },
        .sym_dollar => {
            const expr = try self.allocator.create(Expression);
            expr.* = .{
                .source_range = .{
                    .loc0 = token.source_range.loc0,
                    .loc1 = expr.source_range.loc1,
                },
                .inner = .{ .self_param = try parseSelfParam(self) },
            };
            return expr;
        },
        .sym_at => {
            const expr = try self.allocator.create(Expression);
            expr.* = .{
                .source_range = .{
                    .loc0 = token.source_range.loc0,
                    .loc1 = expr.source_range.loc1,
                },
                .inner = .{ .call = try parseCall(self) },
            };
            return expr;
        },
        .sym_plus => {
            const a = try parseExpression(self, try self.parser.expect());
            const b = try parseExpression(self, try self.parser.expect());
            const expr = try self.allocator.create(Expression);
            expr.* = .{
                .source_range = .{
                    .loc0 = token.source_range.loc0,
                    .loc1 = b.source_range.loc1,
                },
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
            const a = try parseExpression(self, try self.parser.expect());
            const b = try parseExpression(self, try self.parser.expect());
            const expr = try self.allocator.create(Expression);
            expr.* = .{
                .source_range = .{
                    .loc0 = token.source_range.loc0,
                    .loc1 = b.source_range.loc1,
                },
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
            return fail(self.parser.source, token.source_range, "expected expression, found `%`", .{token.source_range});
        },
    }
}

fn paintBlock(
    allocator: *std.mem.Allocator,
    source: Source,
    tokens: []const Token,
    first_pass_result: FirstPassResult,
    module: CustomModule,
    module_index: usize,
) !*const Expression {
    const body_loc = first_pass_result.module_body_locations[module_index].?;
    var self: SecondPass = .{
        .allocator = allocator,
        .tokens = tokens,
        .parser = .{
            .source = source,
            .tokens = tokens[body_loc.begin_token..body_loc.end_token],
            .i = 0,
        },
        .first_pass_result = first_pass_result,
        .module = module,
        .module_index = module_index,
    };
    while (true) {
        const token = try self.parser.expect();
        if (token.tt == .kw_end) {
            break;
        }
        return try parseExpression(&self, token);
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
    first_pass_result: FirstPassResult,
    allocator: *std.mem.Allocator,
) ![]const CodeGenResult {
    var code_gen_results = try allocator.alloc(CodeGenResult, first_pass_result.modules.len);

    for (first_pass_result.modules) |module, i| {
        if (i < builtins.len) {
            code_gen_results[i] = .{
                .instructions = undefined, // FIXME - should be null
                .num_outputs = builtins[i].num_outputs,
                .num_temps = builtins[i].num_temps,
            };
            continue;
        }

        const fields = first_pass_result.module_fields[module.first_field .. module.first_field + module.num_fields];

        const expression = try paintBlock(allocator, source, tokens, first_pass_result, module, i);

        std.debug.warn("module '{}'\n", .{module.name});
        for (fields) |field| {
            std.debug.warn("    field {}: {}\n", .{ field.name, field.type_name });
        }
        std.debug.warn("print expression:\n", .{});
        printExpression(fields, expression, 1);

        // we need to pass the (being mutated) code_gen_results array to this function, because
        // codegen'ing one module needs to know the num_temps of any module that it calls, and
        // codegen is where we actually figure out what num_temps is
        // TODO move this outside the loop (store the expressions in a temporary list).
        // we need to be able to bounce around between modules based on dependencies.
        code_gen_results[i] = try codegen(source, code_gen_results, first_pass_result, i, expression, allocator);
    }

    return code_gen_results;
}

fn printExpression(fields: []const ModuleField, expression: *const Expression, indentation: usize) void {
    var i: usize = 0;
    while (i < indentation) : (i += 1) {
        std.debug.warn("    ", .{});
    }
    switch (expression.inner) {
        .call => |call| {
            std.debug.warn("call self.{} (\n", .{fields[call.field_index].name});
            for (call.args.span()) |arg| {
                i = 0;
                while (i < indentation + 1) : (i += 1) {
                    std.debug.warn("    ", .{});
                }
                std.debug.warn("{}:\n", .{arg.arg_name});
                printExpression(fields, arg.value, indentation + 2);
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
            printExpression(fields, m.a, indentation + 1);
            printExpression(fields, m.b, indentation + 1);
        },
        .nothing => {
            std.debug.warn("(nothing)\n", .{});
        },
    }
}
