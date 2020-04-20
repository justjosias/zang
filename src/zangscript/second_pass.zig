const std = @import("std");
const Source = @import("tokenizer.zig").Source;
const SourceLocation = @import("tokenizer.zig").SourceLocation;
const SourceRange = @import("tokenizer.zig").SourceRange;
const Token = @import("tokenizer.zig").Token;
const TokenType = @import("tokenizer.zig").TokenType;
const TokenIterator = @import("tokenizer.zig").TokenIterator;
const fail = @import("fail.zig").fail;
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
    scope: *Scope,
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
    arena_allocator: *std.mem.Allocator,
    tokens: []const Token,
    token_it: TokenIterator,
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
        return fail(self.token_it.source, field_name_token.source_range, "no module called `<`", .{});
    };
    // add the field
    const field_index = self.fields.items.len;
    try self.fields.append(.{
        .type_token = field_name_token,
        .resolved_module_index = callee_module_index,
    });

    _ = try self.token_it.expectOneOf(&[_]TokenType{.sym_left_paren});
    var args = std.ArrayList(CallArg).init(self.arena_allocator);
    var first = true;
    var token = try self.token_it.expect("`)` or arg name");
    while (token.tt != .sym_right_paren) {
        if (first) {
            first = false;
        } else {
            if (token.tt == .sym_comma) {
                token = try self.token_it.expect("`)` or arg name");
            } else {
                return self.token_it.failExpected("`,` or `)`", token.source_range);
            }
        }
        switch (token.tt) {
            .identifier => {
                const identifier = self.token_it.getSourceString(token.source_range);
                const equals_token = try self.token_it.expect("`=`, `,` or `)`");
                if (equals_token.tt == .sym_equals) {
                    const subexpr = try expectExpression(self, scope);
                    try args.append(.{
                        .param_name = identifier,
                        .param_name_token = token,
                        .value = subexpr,
                    });
                    token = try self.token_it.expect("`)` or arg name");
                } else {
                    // shorthand param passing: `val` expands to `val=val`
                    const inner = parseLocalOrParam(self, scope, identifier) orelse
                        return fail(self.token_it.source, token.source_range, "no param or local called `<`", .{});
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
                return self.token_it.failExpected("`)` or arg name", token.source_range);
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
        const token = try self.token_it.expectOneOf(&[_]TokenType{.number});
        const s = self.token_it.getSourceString(token.source_range);
        const n = std.fmt.parseInt(usize, s, 10) catch {
            return fail(self.token_it.source, token.source_range, "malformatted integer", .{});
        };
        break :blk n;
    };
    // keyword `begin`
    _ = try self.token_it.expectOneOf(&[_]TokenType{.kw_begin});
    // inner statements
    const inner_scope = try parseStatements(self, scope);
    return Delay{
        .num_samples = num_samples,
        .scope = inner_scope,
    };
}

fn createExpr(self: *SecondPass, loc0: SourceLocation, inner: ExpressionInner) !*const Expression {
    // you pass the location of the start of the expression. this function will use the token_it's
    // current location to set the expression's end location
    const loc1 = if (self.token_it.i == 0) loc0 else self.tokens[self.token_it.i - 1].source_range.loc1;
    const expr = try self.arena_allocator.create(Expression);
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
            for (sc.statements.items) |statement| {
                switch (statement) {
                    .let_assignment => |x| {
                        const local = self.locals.items[x.local_index];
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
    const maybe_param_index = for (self.module.params) |param, i| {
        if (std.mem.eql(u8, param.name, name)) {
            break i;
        }
    } else null;
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
    if (if (self.token_it.peek()) |token| token.tt == .sym_minus else false) {
        _ = self.token_it.next();
        negate = true;
    }

    var a = try expectTerm(self, scope);
    const loc0 = a.source_range.loc0;

    if (negate) {
        a = try createExpr(self, loc0, .{ .negate = a });
    }

    while (self.token_it.peek()) |token| {
        for (binary_operators) |bo| {
            if (token.tt == bo.symbol and priority <= bo.priority) {
                _ = self.token_it.next();
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
    const token = try self.token_it.expect("expression");
    const loc0 = token.source_range.loc0;

    switch (token.tt) {
        .sym_left_paren => {
            const a = try expectExpression(self, scope);
            _ = try self.token_it.expectOneOf(&[_]TokenType{.sym_right_paren});
            return a;
        },
        .identifier => {
            const s = self.token_it.getSourceString(token.source_range);
            if (s[0] >= 'A' and s[0] <= 'Z') {
                const call = try parseCall(self, scope, token, s);
                return try createExpr(self, loc0, .{ .call = call });
            }
            const inner = parseLocalOrParam(self, scope, s) orelse
                return fail(self.token_it.source, token.source_range, "no local or param called `<`", .{});
            return try createExpr(self, loc0, inner);
        },
        .kw_false => {
            return try createExpr(self, loc0, .{ .literal_boolean = false });
        },
        .kw_true => {
            return try createExpr(self, loc0, .{ .literal_boolean = true });
        },
        .number => {
            const s = self.token_it.getSourceString(token.source_range);
            const n = std.fmt.parseFloat(f32, s) catch {
                return fail(self.token_it.source, token.source_range, "malformatted number", .{});
            };
            return try createExpr(self, loc0, .{ .literal_number = n });
        },
        .enum_value => {
            const s = self.token_it.getSourceString(token.source_range);
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
            return self.token_it.failExpected("expression", token.source_range);
        },
    }
}

fn parseLetAssignment(self: *SecondPass, scope: *Scope) !void {
    const name_token = try self.token_it.expectOneOf(&[_]TokenType{.identifier});
    const name = self.token_it.getSourceString(name_token.source_range);
    if (name[0] < 'a' or name[0] > 'z') {
        return fail(self.token_it.source, name_token.source_range, "local name must start with a lowercase letter", .{});
    }
    _ = try self.token_it.expectOneOf(&[_]TokenType{.sym_equals});
    // note: locals are allowed to shadow params
    var maybe_s: ?*const Scope = scope;
    while (maybe_s) |s| : (maybe_s = s.parent) {
        for (s.statements.items) |statement| {
            switch (statement) {
                .let_assignment => |x| {
                    const local = self.locals.items[x.local_index];
                    if (std.mem.eql(u8, local.name, name)) {
                        return fail(self.token_it.source, name_token.source_range, "redeclaration of local `<`", .{});
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

fn parseStatements(self: *SecondPass, parent_scope: ?*const Scope) !*Scope {
    var scope = try self.arena_allocator.create(Scope);
    scope.* = .{
        .parent = parent_scope,
        .statements = std.ArrayList(Statement).init(self.arena_allocator),
    };

    while (self.token_it.next()) |token| {
        switch (token.tt) {
            .kw_end => break,
            .kw_let => {
                try parseLetAssignment(self, scope);
            },
            .kw_out => {
                const expr = try expectExpression(self, scope);
                try scope.statements.append(.{ .output = expr });
            },
            .kw_feedback => {
                const expr = try expectExpression(self, scope);
                try scope.statements.append(.{ .feedback = expr });
            },
            else => {
                return self.token_it.failExpected("`let`, `out` or `end`", token.source_range);
            },
        }
    }

    return scope;
}

pub const SecondPassModuleInfo = struct {
    scope: *Scope,
    fields: []const Field,
    locals: []const Local,
};

pub const SecondPassResult = struct {
    arena: std.heap.ArenaAllocator,
    module_infos: []const ?SecondPassModuleInfo, // null for builtins

    pub fn deinit(self: *SecondPassResult) void {
        self.arena.deinit();
    }
};

pub fn secondPass(
    source: Source,
    tokens: []const Token,
    first_pass_result: FirstPassResult,
    inner_allocator: *std.mem.Allocator,
) !SecondPassResult {
    var arena = std.heap.ArenaAllocator.init(inner_allocator);
    errdefer arena.deinit();

    var module_infos = try arena.allocator.alloc(?SecondPassModuleInfo, first_pass_result.modules.len);

    for (first_pass_result.modules) |module, module_index| {
        if (!module.has_body_loc) {
            // it's a builtin
            module_infos[module_index] = null;
            continue;
        }

        var self: SecondPass = .{
            .arena_allocator = &arena.allocator,
            .tokens = tokens,
            .token_it = TokenIterator.init(source, tokens[module.begin_token..module.end_token]),
            .first_pass_result = first_pass_result,
            .module = module,
            .module_index = module_index,
            .fields = std.ArrayList(Field).init(&arena.allocator),
            .locals = std.ArrayList(Local).init(&arena.allocator),
        };

        const top_scope = try parseStatements(&self, null);

        const module_info: SecondPassModuleInfo = .{
            .scope = top_scope,
            .fields = self.fields.toOwnedSlice(),
            .locals = self.locals.toOwnedSlice(),
        };

        module_infos[module_index] = module_info;

        // diagnostic print
        secondPassPrintModule(first_pass_result, module, module_info) catch |err| std.debug.warn("secondPassPrintModule failed: {}\n", .{err});
    }

    return SecondPassResult{
        .arena = arena,
        .module_infos = module_infos,
    };
}
