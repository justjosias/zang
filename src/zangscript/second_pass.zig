const std = @import("std");
const Parser = @import("common.zig").Parser;
const Source = @import("common.zig").Source;
const SourceLocation = @import("common.zig").SourceLocation;
const SourceRange = @import("common.zig").SourceRange;
const fail = @import("common.zig").fail;
const Token = @import("tokenizer.zig").Token;
const FirstPassResult = @import("first_pass.zig").FirstPassResult;
const Module = @import("first_pass.zig").Module;
const ModuleParam = @import("first_pass.zig").ModuleParam;
const ParamType = @import("first_pass.zig").ParamType;
const CodeGenResult = @import("codegen.zig").CodeGenResult;
const GenError = @import("codegen.zig").GenError;
const codegen = @import("codegen.zig").codegen;
const builtins = @import("builtins.zig").builtins;
const secondPassPrintModule = @import("second_pass_print.zig").secondPassPrintModule;

pub const CallArg = struct {
    arg_name: []const u8,
    value: *const Expression,
};

pub const Call = struct {
    field_index: usize, // index of the field in the "self" module
    args: std.ArrayList(CallArg),
};

pub const BinArithOp = enum {
    add,
    mul,
};

pub const BinArith = struct {
    op: BinArithOp,
    a: *const Expression,
    b: *const Expression,
};

pub const ExpressionInner = union(enum) {
    call: Call,
    literal: Literal,
    self_param: usize,
    bin_arith: BinArith,
};

pub const Expression = struct {
    source_range: SourceRange,
    inner: ExpressionInner,
};

// literals have their own datatypes...
pub const Literal = union(enum) {
    boolean: bool,
    number: f32,
};

const SecondPass = struct {
    allocator: *std.mem.Allocator,
    tokens: []const Token,
    parser: Parser,
    first_pass_result: FirstPassResult,
    module: Module,
    module_index: usize,
};

fn parseSelfParam(self: *SecondPass) !usize {
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

const ParseError = error{
    Failed,
    OutOfMemory,
};

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
            const subexpr = try expectExpression(self);
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
            //const self_params = self.first_pass_result.module_params[self.module.first_param .. self.module.first_param + self.module.num_params];
            //const subexpr_type = try getExpressionType(self.parser.source, self_params, subexpr);
            //switch (param_type) {
            //    .boolean => {
            //        if (subexpr_type != .boolean) {
            //            return fail(self.parser.source, subexpr.source_range, "type mismatch (expecting boolean)", .{});
            //        }
            //    },
            //    .buffer => {
            //        // buffer will coerce to constant_or_buffer
            //        if (subexpr_type != .buffer and subexpr_type != .constant_or_buffer) {
            //            return fail(self.parser.source, subexpr.source_range, "type mismatch (expecting number)", .{});
            //        }
            //    },
            //    .constant => {
            //        if (subexpr_type != .constant) {
            //            return fail(self.parser.source, subexpr.source_range, "type mismatch (expecting constant)", .{});
            //        }
            //    },
            //    .constant_or_buffer => {
            //        // constant will coerce to constant_or_buffer
            //        if (subexpr_type != .constant and subexpr_type != .constant_or_buffer) {
            //            return fail(self.parser.source, subexpr.source_range, "type mismatch (expecting number)", .{});
            //        }
            //    },
            //}
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

fn createExpr(self: *SecondPass, loc0: SourceLocation, inner: ExpressionInner) !*const Expression {
    // you pass the location of the start of the expression. this function will use the parser's
    // current location to set the expression's end location
    const loc1 = if (self.parser.i == 0) loc0 else self.parser.tokens[self.parser.i - 1].source_range.loc1;
    const expr = try self.allocator.create(Expression);
    expr.* = .{
        .source_range = .{ .loc0 = loc0, .loc1 = loc1 },
        .inner = inner,
    };
    return expr;
}

fn expectExpression(self: *SecondPass) ParseError!*const Expression {
    const token = try self.parser.expect();
    const loc0 = token.source_range.loc0;

    switch (token.tt) {
        .kw_false => {
            return try createExpr(self, loc0, .{ .literal = .{ .boolean = false } });
        },
        .kw_true => {
            return try createExpr(self, loc0, .{ .literal = .{ .boolean = true } });
        },
        .number => {
            const s = self.parser.source.contents[token.source_range.loc0.index..token.source_range.loc1.index];
            const n = std.fmt.parseFloat(f32, s) catch {
                return fail(self.parser.source, token.source_range, "malformatted number", .{});
            };
            return try createExpr(self, loc0, .{ .literal = .{ .number = n } });
        },
        .sym_dollar => {
            const self_param = try parseSelfParam(self);
            return try createExpr(self, loc0, .{ .self_param = self_param });
        },
        .sym_at => {
            const call = try parseCall(self);
            return try createExpr(self, loc0, .{ .call = call });
        },
        .sym_plus => {
            const a = try expectExpression(self);
            const b = try expectExpression(self);
            return try createExpr(self, loc0, .{ .bin_arith = .{ .op = .add, .a = a, .b = b } });
        },
        .sym_asterisk => {
            const a = try expectExpression(self);
            const b = try expectExpression(self);
            return try createExpr(self, loc0, .{ .bin_arith = .{ .op = .mul, .a = a, .b = b } });
        },
        else => {
            return fail(self.parser.source, token.source_range, "expected expression, found `%`", .{token.source_range});
        },
    }
}

fn paintBlock(
    allocator: *std.mem.Allocator,
    source: Source,
    tokens: []const Token,
    first_pass_result: FirstPassResult,
    module: Module,
    module_index: usize,
) !*const Expression {
    const body_loc = first_pass_result.module_body_locations[module_index].?; // this is only null for builtin modules
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
    const expression = try expectExpression(&self);
    const token = try self.parser.expect();
    if (token.tt != .kw_end) {
        return fail(source, token.source_range, "expected `end`, found `%`", .{token.source_range});
    }
    return expression;
}

pub fn secondPass(
    source: Source,
    tokens: []const Token,
    first_pass_result: FirstPassResult,
    allocator: *std.mem.Allocator,
) ![]const CodeGenResult {
    // parse paint expressions
    var expressions = try allocator.alloc(*const Expression, first_pass_result.modules.len - builtins.len);
    defer allocator.free(expressions);

    for (first_pass_result.modules) |module, i| {
        if (i < builtins.len) {
            continue;
        }

        const expression = try paintBlock(allocator, source, tokens, first_pass_result, module, i);

        expressions[i - builtins.len] = expression;

        // diagnostic print
        secondPassPrintModule(first_pass_result, module, expression, 1);
    }

    // do codegen (turning expressions into instructions and figuring out the num_temps for each module).
    // this has to be done in "dependency order", since a module needs to know the num_temps of its fields
    // before it can figure out its own num_temps.
    // codegen_visited tracks which modules we have visited so far.
    var codegen_visited = try allocator.alloc(bool, first_pass_result.modules.len);
    defer allocator.free(codegen_visited);
    std.mem.set(bool, codegen_visited, false);

    var codegen_results = try allocator.alloc(CodeGenResult, first_pass_result.modules.len);

    for (first_pass_result.modules) |module, i| {
        if (i < builtins.len) {
            codegen_results[i] = .{
                .instructions = undefined, // FIXME - should be null
                .num_outputs = builtins[i].num_outputs,
                .num_temps = builtins[i].num_temps,
            };
            codegen_visited[i] = true;
            continue;
        }

        try codegenVisit(source, first_pass_result, expressions, codegen_visited, codegen_results, i, i, allocator);
    }

    return codegen_results;
}

fn codegenVisit(
    source: Source,
    first_pass_result: FirstPassResult,
    expressions: []*const Expression,
    visited: []bool,
    results: []CodeGenResult,
    self_module_index: usize,
    module_index: usize,
    allocator: *std.mem.Allocator,
) GenError!void {
    if (visited[module_index]) {
        return;
    }

    visited[module_index] = true;

    // first, recursively resolve all modules that this one uses as its fields
    const module = first_pass_result.modules[module_index];
    const fields = first_pass_result.module_fields[module.first_field .. module.first_field + module.num_fields];
    for (fields) |field, field_index| {
        if (field.resolved_module_index == self_module_index) {
            return fail(source, field.type_token.source_range, "circular dependency in module fields", .{});
        }

        try codegenVisit(source, first_pass_result, expressions, visited, results, self_module_index, field.resolved_module_index, allocator);
    }

    // now resolve this one
    // note: the codegen function reads from the `results` array to look up the num_temps of the fields
    const expression = expressions[module_index - builtins.len];
    results[module_index] = try codegen(source, results, first_pass_result, module_index, expression, allocator);
}
