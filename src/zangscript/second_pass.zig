const std = @import("std");
const Parser = @import("common.zig").Parser;
const Source = @import("common.zig").Source;
const SourceLocation = @import("common.zig").SourceLocation;
const SourceRange = @import("common.zig").SourceRange;
const fail = @import("common.zig").fail;
const Token = @import("tokenizer.zig").Token;
const TokenType = @import("tokenizer.zig").TokenType;
const FirstPassResult = @import("first_pass.zig").FirstPassResult;
const Module = @import("first_pass.zig").Module;
const ModuleParam = @import("first_pass.zig").ModuleParam;
const ParamType = @import("first_pass.zig").ParamType;
const CodeGenResult = @import("codegen.zig").CodeGenResult;
const GenError = @import("codegen.zig").GenError;
const codegen = @import("codegen.zig").codegen;
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
    pow,
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
    literal_boolean: bool,
    literal_number: f32,
    literal_enum_value: []const u8,
    self_param: usize,
    negate: *const Expression,
    bin_arith: BinArith,
    local: usize, // index into flat `locals` array
    feedback, // only allowed within `delay` expressions
};

pub const Expression = struct {
    source_range: SourceRange,
    inner: ExpressionInner,
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

const ParseError = error{
    Failed,
    OutOfMemory,
};

fn parseCall(self: *SecondPass, scope: *const Scope, field_name_token: Token, field_name: []const u8) ParseError!Call {
    // resolve module name
    const callee_module_index = for (self.first_pass_result.modules) |module, i| {
        if (std.mem.eql(u8, field_name, module.name)) {
            break i;
        }
    } else {
        return fail(self.parser.source, field_name_token.source_range, "no module called `<`", .{});
    };
    // add the field
    const field_index = self.fields.items.len;
    try self.fields.append(.{
        .type_token = field_name_token,
        .resolved_module_index = callee_module_index,
    });

    var token = try self.parser.expect();
    if (token.tt != .sym_left_paren) {
        return fail(self.parser.source, token.source_range, "expected `(`, found `<`", .{});
    }
    var args = std.ArrayList(CallArg).init(self.allocator);
    errdefer args.deinit();
    var first = true;
    token = try self.parser.expect();
    while (token.tt != .sym_right_paren) {
        if (first) {
            first = false;
        } else {
            if (token.tt == .sym_comma) {
                token = try self.parser.expect();
            } else {
                return fail(self.parser.source, token.source_range, "expected `,` or `)`, found `<`", .{});
            }
        }
        switch (token.tt) {
            .identifier => {
                const identifier = self.parser.source.contents[token.source_range.loc0.index..token.source_range.loc1.index];
                const equals_token = try self.parser.expect();
                if (equals_token.tt == .sym_equals) {
                    const subexpr = try expectExpression(self, scope);
                    try args.append(.{
                        .param_name = identifier,
                        .param_name_token = token,
                        .value = subexpr,
                    });
                    token = try self.parser.expect();
                } else {
                    // shorthand param passing: `val` expands to `val=val`
                    const inner = parseLocalOrParam(self, scope, identifier) orelse
                        return fail(self.parser.source, token.source_range, "no param or local called `<`", .{});
                    const loc0 = token.source_range.loc0;
                    const subexpr = try createExpr(self, loc0, inner);
                    try args.append(.{
                        .param_name = identifier,
                        .param_name_token = token,
                        .value = subexpr,
                    });
                    token = equals_token;
                }
            },
            else => {
                return fail(self.parser.source, token.source_range, "expected `)` or arg name, found `<`", .{});
            },
        }
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
        return fail(self.parser.source, begin_token.source_range, "expected `begin`, found `<`", .{});
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

fn parseLocalOrParam(self: *SecondPass, scope: *const Scope, name: []const u8) ?ExpressionInner {
    const maybe_local_index = blk: {
        var maybe_s: ?*const Scope = scope;
        while (maybe_s) |sc| : (maybe_s = sc.parent) {
            for (sc.statements.span()) |statement| {
                switch (statement) {
                    .let_assignment => |x| {
                        const local = self.locals.span()[x.local_index];
                        if (std.mem.eql(u8, local.name, name)) {
                            break :blk x.local_index;
                        }
                    },
                    else => {},
                }
            }
        }
        break :blk null;
    };
    if (maybe_local_index) |local_index| {
        return ExpressionInner{ .local = local_index };
    }
    const maybe_param_index = blk: {
        const params = self.first_pass_result.module_params[self.module.first_param .. self.module.first_param + self.module.num_params];
        for (params) |param, i| {
            if (std.mem.eql(u8, param.name, name)) {
                break :blk i;
            }
        }
        break :blk null;
    };
    if (maybe_param_index) |param_index| {
        return ExpressionInner{ .self_param = param_index };
    }
    return null;
}

const BinaryOperator = struct {
    symbol: TokenType,
    priority: usize,
    op: BinArithOp,
};

const binary_operators = [_]BinaryOperator{
    .{ .symbol = .sym_plus, .priority = 1, .op = .add },
    .{ .symbol = .sym_asterisk, .priority = 2, .op = .mul },
    // note: exponentiation operator is not associative, unlike add and mul.
    // maybe i should make it an error to type `x**y**z` without putting one of
    // the pairs in parentheses.
    .{ .symbol = .sym_dbl_asterisk, .priority = 3, .op = .pow },
};

fn expectExpression(self: *SecondPass, scope: *const Scope) ParseError!*const Expression {
    return expectExpression2(self, scope, 0);
}

fn expectExpression2(self: *SecondPass, scope: *const Scope, priority: usize) ParseError!*const Expression {
    var negate = false;
    if (if (self.parser.peek()) |token| token.tt == .sym_minus else false) {
        _ = try self.parser.expect();
        negate = true;
    }

    var a = try expectTerm(self, scope);
    const loc0 = a.source_range.loc0;

    if (negate) {
        a = try createExpr(self, loc0, .{ .negate = a });
    }

    while (self.parser.peek()) |token| {
        for (binary_operators) |bo| {
            if (token.tt == bo.symbol and priority <= bo.priority) {
                _ = self.parser.next();
                const b = try expectExpression2(self, scope, bo.priority);
                a = try createExpr(self, loc0, .{ .bin_arith = .{ .op = bo.op, .a = a, .b = b } });
                break;
            }
        } else {
            break;
        }
    }

    return a;
}

fn expectTerm(self: *SecondPass, scope: *const Scope) ParseError!*const Expression {
    const token = try self.parser.expect();
    const loc0 = token.source_range.loc0;

    switch (token.tt) {
        .sym_left_paren => {
            const a = try expectExpression(self, scope);
            const paren_token = try self.parser.expect();
            if (paren_token.tt != .sym_right_paren) {
                return fail(self.parser.source, paren_token.source_range, "expected `)`, found `<`", .{});
            }
            return a;
        },
        .identifier => {
            const s = self.parser.source.contents[token.source_range.loc0.index..token.source_range.loc1.index];
            if (s[0] >= 'A' and s[0] <= 'Z') {
                const call = try parseCall(self, scope, token, s);
                return try createExpr(self, loc0, .{ .call = call });
            }
            const inner = parseLocalOrParam(self, scope, s) orelse
                return fail(self.parser.source, token.source_range, "no local or param called `<`", .{});
            return try createExpr(self, loc0, inner);
        },
        .kw_false => {
            return try createExpr(self, loc0, .{ .literal_boolean = false });
        },
        .kw_true => {
            return try createExpr(self, loc0, .{ .literal_boolean = true });
        },
        .number => {
            const s = self.parser.source.contents[token.source_range.loc0.index..token.source_range.loc1.index];
            const n = std.fmt.parseFloat(f32, s) catch {
                return fail(self.parser.source, token.source_range, "malformatted number", .{});
            };
            return try createExpr(self, loc0, .{ .literal_number = n });
        },
        .enum_value => {
            const s = self.parser.source.contents[token.source_range.loc0.index..token.source_range.loc1.index];
            return try createExpr(self, loc0, .{ .literal_enum_value = s });
        },
        .kw_delay => {
            const delay = try parseDelay(self, scope);
            return try createExpr(self, loc0, .{ .delay = delay });
        },
        .kw_feedback => {
            return try createExpr(self, loc0, .feedback);
        },
        else => {
            return fail(self.parser.source, token.source_range, "expected expression, found `<`", .{});
        },
    }
}

fn parseLetAssignment(self: *SecondPass, scope: *Scope) !void {
    const name_token = try self.parser.expect();
    if (name_token.tt != .identifier) {
        return fail(self.parser.source, name_token.source_range, "expected identifier", .{});
    }
    const name = self.parser.source.contents[name_token.source_range.loc0.index..name_token.source_range.loc1.index];
    if (name[0] < 'a' or name[0] > 'z') {
        return fail(self.parser.source, name_token.source_range, "local name must start with a lowercase letter", .{});
    }
    const equals_token = try self.parser.expect();
    if (equals_token.tt != .sym_equals) {
        return fail(self.parser.source, equals_token.source_range, "expect `=`, found `<`", .{});
    }
    // note: locals are allowed to shadow params
    var maybe_s: ?*const Scope = scope;
    while (maybe_s) |s| : (maybe_s = s.parent) {
        for (s.statements.span()) |statement| {
            switch (statement) {
                .let_assignment => |x| {
                    const local = self.locals.span()[x.local_index];
                    if (std.mem.eql(u8, local.name, name)) {
                        return fail(self.parser.source, name_token.source_range, "redeclaration of local `<`", .{});
                    }
                },
                .output => {},
                .feedback => {},
            }
        }
    }
    const expr = try expectExpression(self, scope);
    const local_index = self.locals.items.len;
    try self.locals.append(.{
        .name = name,
    });
    try scope.statements.append(.{
        .let_assignment = .{
            .local_index = local_index,
            .expression = expr,
        },
    });
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
                try parseLetAssignment(self, scope);
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
                return fail(self.parser.source, token.source_range, "expected `let`, `out` or `end`, found `<`", .{});
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
    const num_builtins = blk: {
        var n: usize = 0;
        for (first_pass_result.builtin_packages) |pkg| {
            n += pkg.builtins.len;
        }
        break :blk n;
    };

    // parse paint blocks
    var module_scopes = try allocator.alloc(*const Scope, first_pass_result.modules.len - num_builtins);
    defer allocator.free(module_scopes);

    var module_fields = try allocator.alloc([]const Field, first_pass_result.modules.len - num_builtins);
    defer allocator.free(module_fields);

    var module_locals = try allocator.alloc([]const Local, first_pass_result.modules.len - num_builtins);
    defer allocator.free(module_locals);

    for (first_pass_result.modules) |module, module_index| {
        if (module_index < num_builtins) {
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

        module_scopes[module_index - num_builtins] = top_scope;
        module_fields[module_index - num_builtins] = self.fields.span(); // TODO toOwnedSlice?
        module_locals[module_index - num_builtins] = self.locals.span(); // TODO toOwnedSlice?

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

    var builtin_index: usize = 0;
    for (first_pass_result.builtin_packages) |pkg| {
        for (pkg.builtins) |builtin| {
            codegen_results[builtin_index] = .{
                .instructions = undefined, // FIXME - should be null
                .num_outputs = builtin.num_outputs,
                .num_temps = builtin.num_temps,
                .fields = undefined, // FIXME - should be null?
                .delays = undefined, // FIXME - should be null?
            };
            codegen_visited[builtin_index] = true;
            builtin_index += 1;
        }
    }
    for (first_pass_result.modules) |module, i| {
        if (i < num_builtins) {
            continue;
        }
        try codegenVisit(source, first_pass_result, num_builtins, module_scopes, codegen_visited, codegen_results, i, i, module_fields, module_locals, allocator);
    }

    return codegen_results;
}

fn codegenVisit(
    source: Source,
    first_pass_result: FirstPassResult,
    num_builtins: usize,
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
    const fields = module_fields[module_index - num_builtins];

    for (fields) |field, field_index| {
        if (field.resolved_module_index == self_module_index) {
            return fail(source, field.type_token.source_range, "circular dependency in module fields", .{});
        }

        try codegenVisit(source, first_pass_result, num_builtins, module_scopes, visited, results, self_module_index, field.resolved_module_index, module_fields, module_locals, allocator);
    }

    // now resolve this one
    // note: the codegen function reads from the `results` array to look up the num_temps of the fields
    const scope = module_scopes[module_index - num_builtins];
    const locals = module_locals[module_index - num_builtins];
    results[module_index] = try codegen(source, results, first_pass_result, module_index, fields, locals, scope, allocator);
}
