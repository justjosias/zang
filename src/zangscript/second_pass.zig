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

pub const Scope = struct {
    parent: ?*const Scope,
    statements: std.ArrayList(Statement),
};

pub const CallArg = struct {
    param_name: []const u8,
    param_name_token: Token,
    value: *const Expression,
};

pub const Call = struct {
    field_index: usize, // index of the field in the "self" module
    args: []const CallArg,
};

pub const Delay = struct {
    num_samples: usize,
    scope: *const Scope,
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

pub const Local = struct {
    name: []const u8,
};

pub const ExpressionInner = union(enum) {
    call: Call,
    delay: Delay,
    literal: Literal,
    self_param: usize,
    bin_arith: BinArith,
    local: usize, // index into flat `locals` array
    feedback, // only allowed within `delay` expressions
};

pub const Expression = struct {
    source_range: SourceRange,
    inner: ExpressionInner,
};

pub const Literal = union(enum) {
    boolean: bool,
    number: f32,
    enum_value: []const u8,
};

pub const LetAssignment = struct {
    local_index: usize,
    expression: *const Expression,
};

pub const Statement = union(enum) {
    let_assignment: LetAssignment,
    output: *const Expression,
    feedback: *const Expression,
};

pub const Field = struct {
    type_token: Token,
    resolved_module_index: usize,
};

const SecondPass = struct {
    allocator: *std.mem.Allocator,
    tokens: []const Token,
    parser: Parser,
    first_pass_result: FirstPassResult,
    module: Module,
    module_index: usize,
    fields: std.ArrayList(Field),
    locals: std.ArrayList(Local),
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
    return param_index;
}

const ParseError = error{
    Failed,
    OutOfMemory,
};

fn parseCallArg(self: *SecondPass, scope: *const Scope, token: Token) ParseError!CallArg {
    switch (token.tt) {
        .identifier => {
            const identifier = self.parser.source.contents[token.source_range.loc0.index..token.source_range.loc1.index];
            const colon_token = try self.parser.expect();
            if (colon_token.tt != .sym_colon) {
                return fail(self.parser.source, colon_token.source_range, "expected `:`, found `%`", .{colon_token.source_range});
            }
            const subexpr = try expectExpression(self, scope);
            return CallArg{
                .param_name = identifier,
                .param_name_token = token,
                .value = subexpr,
            };
        },
        else => {
            return fail(self.parser.source, token.source_range, "expected `)` or arg name, found `%`", .{token.source_range});
        },
    }
}

fn parseCall(self: *SecondPass, scope: *const Scope) ParseError!Call {
    // referencing one of the fields. like a function call
    const field_name_token = try self.parser.expect();
    const field_name = switch (field_name_token.tt) {
        .identifier => self.parser.source.contents[field_name_token.source_range.loc0.index..field_name_token.source_range.loc1.index],
        else => return fail(self.parser.source, field_name_token.source_range, "expected field name, found `%`", .{field_name_token.source_range}),
    };

    // resolve module name
    const callee_module_index = for (self.first_pass_result.modules) |module, i| {
        if (std.mem.eql(u8, field_name, module.name)) {
            break i;
        }
    } else {
        return fail(self.parser.source, field_name_token.source_range, "no module called `%`", .{field_name_token.source_range});
    };
    // add the field
    const field_index = self.fields.len;
    try self.fields.append(.{
        .type_token = field_name_token,
        .resolved_module_index = callee_module_index,
    });

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
        const arg = try parseCallArg(self, scope, token);
        try args.append(arg);
    }
    return Call{
        .field_index = field_index,
        .args = args.toOwnedSlice(),
    };
}

fn parseDelay(self: *SecondPass, scope: *const Scope) ParseError!Delay {
    // constant number for the number of delay samples (this is a limitation of my current delay implementation)
    const num_samples = blk: {
        const token = try self.parser.expect();
        const s = self.parser.source.contents[token.source_range.loc0.index..token.source_range.loc1.index];
        const n = std.fmt.parseInt(usize, s, 10) catch {
            return fail(self.parser.source, token.source_range, "malformatted integer", .{});
        };
        break :blk n;
    };
    // keyword `begin`
    const begin_token = try self.parser.expect();
    if (begin_token.tt != .kw_begin) {
        return fail(self.parser.source, begin_token.source_range, "expected `begin`, found `%`", .{begin_token.source_range});
    }
    // inner statements
    const inner_scope = try parseStatements(self, scope);
    return Delay{
        .num_samples = num_samples,
        .scope = inner_scope,
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

fn expectExpression(self: *SecondPass, scope: *const Scope) ParseError!*const Expression {
    const token = try self.parser.expect();
    const loc0 = token.source_range.loc0;

    switch (token.tt) {
        .identifier => {
            const s = self.parser.source.contents[token.source_range.loc0.index..token.source_range.loc1.index];
            const local_index = blk: {
                var maybe_s: ?*const Scope = scope;
                while (maybe_s) |sc| : (maybe_s = sc.parent) {
                    for (sc.statements.span()) |statement| {
                        switch (statement) {
                            .let_assignment => |x| {
                                const local = self.locals.span()[x.local_index];
                                if (std.mem.eql(u8, local.name, s)) {
                                    break :blk x.local_index;
                                }
                            },
                            else => {},
                        }
                    }
                }
                return fail(self.parser.source, token.source_range, "no local called `%`", .{token.source_range});
            };
            return try createExpr(self, loc0, .{ .local = local_index });
        },
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
        .enum_value => {
            const s = self.parser.source.contents[token.source_range.loc0.index..token.source_range.loc1.index];
            return try createExpr(self, loc0, .{ .literal = .{ .enum_value = s } });
        },
        .sym_dollar => {
            const self_param = try parseSelfParam(self);
            return try createExpr(self, loc0, .{ .self_param = self_param });
        },
        .sym_at => {
            const call = try parseCall(self, scope);
            return try createExpr(self, loc0, .{ .call = call });
        },
        .sym_plus => {
            const a = try expectExpression(self, scope);
            const b = try expectExpression(self, scope);
            return try createExpr(self, loc0, .{ .bin_arith = .{ .op = .add, .a = a, .b = b } });
        },
        .sym_asterisk => {
            const a = try expectExpression(self, scope);
            const b = try expectExpression(self, scope);
            return try createExpr(self, loc0, .{ .bin_arith = .{ .op = .mul, .a = a, .b = b } });
        },
        .kw_delay => {
            const delay = try parseDelay(self, scope);
            return try createExpr(self, loc0, .{ .delay = delay });
        },
        .kw_feedback => {
            return try createExpr(self, loc0, .feedback);
        },
        else => {
            return fail(self.parser.source, token.source_range, "expected expression, found `%`", .{token.source_range});
        },
    }
}

fn parseStatements(self: *SecondPass, parent_scope: ?*const Scope) !*const Scope {
    var scope = try self.allocator.create(Scope);
    scope.* = .{
        .parent = parent_scope,
        .statements = std.ArrayList(Statement).init(self.allocator),
    };

    while (self.parser.next()) |token| {
        switch (token.tt) {
            .kw_end => break,
            .kw_let => {
                const name_token = try self.parser.expect();
                if (name_token.tt != .identifier) {
                    return fail(self.parser.source, name_token.source_range, "expected identifier", .{});
                }
                const name = self.parser.source.contents[name_token.source_range.loc0.index..name_token.source_range.loc1.index];
                const equals_token = try self.parser.expect();
                if (equals_token.tt != .sym_equals) {
                    return fail(self.parser.source, equals_token.source_range, "expect `=`, found `%`", .{equals_token.source_range});
                }
                var maybe_s: ?*const Scope = scope;
                while (maybe_s) |s| : (maybe_s = s.parent) {
                    for (s.statements.span()) |statement| {
                        switch (statement) {
                            .let_assignment => |x| {
                                const local = self.locals.span()[x.local_index];
                                if (std.mem.eql(u8, local.name, name)) {
                                    return fail(self.parser.source, name_token.source_range, "redeclaration of local `#`", .{name});
                                }
                            },
                            .output => {},
                            .feedback => {},
                        }
                    }
                }
                const expr = try expectExpression(self, scope);
                const local_index = self.locals.len;
                try self.locals.append(.{
                    .name = name,
                });
                try scope.statements.append(.{
                    .let_assignment = .{
                        .local_index = local_index,
                        .expression = expr,
                    },
                });
            },
            .kw_out => {
                const expr = try expectExpression(self, scope);
                try scope.statements.append(.{
                    .output = expr,
                });
            },
            .kw_feedback => {
                const expr = try expectExpression(self, scope);
                try scope.statements.append(.{
                    .feedback = expr,
                });
            },
            else => {
                return fail(self.parser.source, token.source_range, "expected `let`, `out` or `end`, found `%`", .{token.source_range});
            },
        }
    }

    return scope;
}

pub fn secondPass(
    source: Source,
    tokens: []const Token,
    first_pass_result: FirstPassResult,
    allocator: *std.mem.Allocator,
) ![]const CodeGenResult {
    // parse paint blocks
    var module_scopes = try allocator.alloc(*const Scope, first_pass_result.modules.len - builtins.len);
    defer allocator.free(module_scopes);

    var module_fields = try allocator.alloc([]const Field, first_pass_result.modules.len - builtins.len);
    defer allocator.free(module_fields);

    var module_locals = try allocator.alloc([]const Local, first_pass_result.modules.len - builtins.len);
    defer allocator.free(module_locals);

    for (first_pass_result.modules) |module, module_index| {
        if (module_index < builtins.len) {
            continue;
        }
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
            .fields = std.ArrayList(Field).init(allocator),
            .locals = std.ArrayList(Local).init(allocator),
        };

        const top_scope = try parseStatements(&self, null);

        module_scopes[module_index - builtins.len] = top_scope;
        module_fields[module_index - builtins.len] = self.fields.span(); // TODO toOwnedSlice?
        module_locals[module_index - builtins.len] = self.locals.span(); // TODO toOwnedSlice?

        // diagnostic print
        secondPassPrintModule(first_pass_result, module, self.fields.span(), self.locals.span(), top_scope, 1);
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
                .fields = undefined, // FIXME - should be null?
                .delays = undefined, // FIXME - should be null?
            };
            codegen_visited[i] = true;
            continue;
        }
        try codegenVisit(source, first_pass_result, module_scopes, codegen_visited, codegen_results, i, i, module_fields, module_locals, allocator);
    }

    return codegen_results;
}

fn codegenVisit(
    source: Source,
    first_pass_result: FirstPassResult,
    module_scopes: []const *const Scope,
    visited: []bool,
    results: []CodeGenResult,
    self_module_index: usize,
    module_index: usize,
    module_fields: []const []const Field,
    module_locals: []const []const Local,
    allocator: *std.mem.Allocator,
) GenError!void {
    if (visited[module_index]) {
        return;
    }

    visited[module_index] = true;

    // first, recursively resolve all modules that this one uses as its fields
    const fields = module_fields[module_index - builtins.len];

    for (fields) |field, field_index| {
        if (field.resolved_module_index == self_module_index) {
            return fail(source, field.type_token.source_range, "circular dependency in module fields", .{});
        }

        try codegenVisit(source, first_pass_result, module_scopes, visited, results, self_module_index, field.resolved_module_index, module_fields, module_locals, allocator);
    }

    // now resolve this one
    // note: the codegen function reads from the `results` array to look up the num_temps of the fields
    const scope = module_scopes[module_index - builtins.len];
    const locals = module_locals[module_index - builtins.len];
    results[module_index] = try codegen(source, results, first_pass_result, module_index, fields, locals, scope, allocator);
}
