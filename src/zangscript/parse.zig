const std = @import("std");
const Source = @import("tokenize.zig").Source;
const SourceLocation = @import("tokenize.zig").SourceLocation;
const SourceRange = @import("tokenize.zig").SourceRange;
const Token = @import("tokenize.zig").Token;
const TokenType = @import("tokenize.zig").TokenType;
const Tokenizer = @import("tokenize.zig").Tokenizer;
const fail = @import("fail.zig").fail;
const BuiltinEnum = @import("builtins.zig").BuiltinEnum;
const BuiltinPackage = @import("builtins.zig").BuiltinPackage;
const parsePrintModule = @import("parse_print.zig").parsePrintModule;

pub const ParamType = union(enum) {
    boolean,
    buffer,
    constant,
    constant_or_buffer,
    one_of: BuiltinEnum,
};

pub const ModuleParam = struct {
    name: []const u8,
    param_type: ParamType,
};

pub const Field = struct {
    type_token: Token,
};

pub const ParsedModuleInfo = struct {
    scope: *Scope,
    fields: []const Field,
    locals: []const Local,
};

pub const Module = struct {
    name: []const u8,
    params: []const ModuleParam,
    zig_package_name: ?[]const u8, // only set for builtin modules
    info: ?ParsedModuleInfo, // null for builtin modules
};

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

pub const UnArithOp = enum {
    abs,
    cos,
    neg,
    sin,
    sqrt,
};

pub const UnArith = struct {
    op: UnArithOp,
    a: *const Expression,
};

pub const BinArithOp = enum {
    add,
    div,
    max,
    min,
    mul,
    pow,
    sub,
};

pub const BinArith = struct {
    op: BinArithOp,
    a: *const Expression,
    b: *const Expression,
};

pub const Local = struct {
    name: []const u8,
};

pub const NumberLiteral = struct {
    value: f32,
    // copy the number literal verbatim from the script so we don't get things
    // like 0.7 becoming 0.699999988079071
    verbatim: []const u8,
};

pub const EnumLiteral = struct {
    label: []const u8,
    payload: ?*const Expression,
};

pub const ExpressionInner = union(enum) {
    call: Call,
    delay: Delay,
    literal_boolean: bool,
    literal_number: NumberLiteral,
    literal_enum_value: EnumLiteral,
    self_param: usize,
    un_arith: UnArith,
    bin_arith: BinArith,
    local: usize, // index into flat `locals` array
    feedback, // only allowed within `delay` expressions
};

pub const Expression = struct {
    source_range: SourceRange,
    inner: ExpressionInner,
};

pub const Statement = union(enum) {
    let_assignment: struct { local_index: usize, expression: *const Expression },
    output: *const Expression,
    feedback: *const Expression,
};

const ParseState = struct {
    arena_allocator: *std.mem.Allocator,
    tokenizer: Tokenizer,
    enums: std.ArrayList(BuiltinEnum),
    modules: std.ArrayList(Module),
};

const ParseModuleState = struct {
    params: []const ModuleParam,
    fields: std.ArrayList(Field),
    locals: std.ArrayList(Local),
};

// names that you can't use for params or locals because they are builtin functions or constants
const reserved_names = [_][]const u8{
    "abs",
    "cos",
    "max",
    "min",
    "pi",
    "pow",
    "sin",
    "sqrt",
};

fn expectParamType(ps: *ParseState) !ParamType {
    const type_token = try ps.tokenizer.next();
    const type_name = ps.tokenizer.source.getString(type_token.source_range);
    if (type_token.tt == .lowercase_name or type_token.tt == .uppercase_name) {
        if (std.mem.eql(u8, type_name, "boolean")) return .boolean;
        if (std.mem.eql(u8, type_name, "constant")) return .constant;
        if (std.mem.eql(u8, type_name, "waveform")) return .buffer;
        if (std.mem.eql(u8, type_name, "cob")) return .constant_or_buffer;
        for (ps.enums.items) |e| {
            if (std.mem.eql(u8, e.name, type_name)) {
                return ParamType{ .one_of = e };
            }
        }
    }
    return ps.tokenizer.failExpected("param type", type_token);
}

fn defineModule(ps: *ParseState) !void {
    const module_name_token = try ps.tokenizer.next();
    if (module_name_token.tt == .lowercase_name) {
        return fail(ps.tokenizer.source, module_name_token.source_range, "module name must start with a capital letter", .{});
    } else if (module_name_token.tt != .uppercase_name) {
        return ps.tokenizer.failExpected("module name", module_name_token);
    }
    const module_name = ps.tokenizer.source.getString(module_name_token.source_range);
    try ps.tokenizer.expectNext(.sym_colon);

    var params = std.ArrayList(ModuleParam).init(ps.arena_allocator);

    while (true) {
        const token = try ps.tokenizer.next();
        switch (token.tt) {
            .kw_begin => break,
            .uppercase_name => return fail(ps.tokenizer.source, token.source_range, "param name must start with a lowercase letter", .{}),
            .lowercase_name => {
                const param_name = ps.tokenizer.source.getString(token.source_range);
                for (reserved_names) |name| {
                    if (std.mem.eql(u8, name, param_name)) {
                        return fail(ps.tokenizer.source, token.source_range, "`<` is a reserved name", .{});
                    }
                }
                for (params.items) |param| {
                    if (std.mem.eql(u8, param.name, param_name)) {
                        return fail(ps.tokenizer.source, token.source_range, "redeclaration of param `<`", .{});
                    }
                }
                try ps.tokenizer.expectNext(.sym_colon);
                const param_type = try expectParamType(ps);
                try ps.tokenizer.expectNext(.sym_comma);
                try params.append(.{
                    .name = param_name,
                    .param_type = param_type,
                });
            },
            else => return ps.tokenizer.failExpected("param declaration or `begin`", token),
        }
    }

    // parse paint block
    var ps_mod: ParseModuleState = .{
        .params = params.toOwnedSlice(),
        .fields = std.ArrayList(Field).init(ps.arena_allocator),
        .locals = std.ArrayList(Local).init(ps.arena_allocator),
    };

    const top_scope = try parseStatements(ps, &ps_mod, null);

    // FIXME a zig compiler bug prevents me from doing this all in one literal
    // (it compiles but then segfaults at runtime)
    var module: Module = .{
        .name = module_name,
        .zig_package_name = null,
        .params = ps_mod.params,
        .info = null,
    };
    module.info = .{
        .scope = top_scope,
        .fields = ps_mod.fields.toOwnedSlice(),
        .locals = ps_mod.locals.toOwnedSlice(),
    };
    try ps.modules.append(module);
}

const ParseError = error{
    Failed,
    OutOfMemory,
};

fn parseCall(ps: *ParseState, ps_mod: *ParseModuleState, scope: *const Scope, field_name_token: Token, field_name: []const u8) ParseError!Call {
    // each call implicitly adds a "field" (child module), since modules have state
    const field_index = ps_mod.fields.items.len;
    try ps_mod.fields.append(.{
        .type_token = field_name_token,
    });

    try ps.tokenizer.expectNext(.sym_left_paren);
    var args = std.ArrayList(CallArg).init(ps.arena_allocator);
    var token = try ps.tokenizer.next();
    while (token.tt != .sym_right_paren) {
        if (args.items.len > 0) {
            if (token.tt != .sym_comma) {
                return ps.tokenizer.failExpected("`,` or `)`", token);
            }
            token = try ps.tokenizer.next();
        }
        if (token.tt != .lowercase_name) {
            return ps.tokenizer.failExpected("callee param name", token);
        }
        const param_name = ps.tokenizer.source.getString(token.source_range);
        const equals_token = try ps.tokenizer.next();
        if (equals_token.tt == .sym_equals) {
            const subexpr = try expectExpression(ps, ps_mod, scope);
            try args.append(.{
                .param_name = param_name,
                .param_name_token = token,
                .value = subexpr,
            });
            token = try ps.tokenizer.next();
        } else {
            // shorthand param passing: `val` expands to `val=val`
            const inner = try requireLocalOrParam(ps, ps_mod, scope, token.source_range);
            const subexpr = try createExprWithSourceRange(ps, token.source_range, inner);
            try args.append(.{
                .param_name = param_name,
                .param_name_token = token,
                .value = subexpr,
            });
            token = equals_token;
        }
    }
    return Call{
        .field_index = field_index,
        .args = args.toOwnedSlice(),
    };
}

fn parseDelay(ps: *ParseState, ps_mod: *ParseModuleState, scope: *const Scope) ParseError!Delay {
    // constant number for the number of delay samples (this is a limitation of my current delay implementation)
    const num_samples = blk: {
        const token = try ps.tokenizer.next();
        if (token.tt != .number) {
            return ps.tokenizer.failExpected("number", token);
        }
        const s = ps.tokenizer.source.getString(token.source_range);
        const n = std.fmt.parseInt(usize, s, 10) catch {
            return fail(ps.tokenizer.source, token.source_range, "malformatted integer", .{});
        };
        break :blk n;
    };
    // keyword `begin`
    try ps.tokenizer.expectNext(.kw_begin);
    // inner statements
    const inner_scope = try parseStatements(ps, ps_mod, scope);
    return Delay{
        .num_samples = num_samples,
        .scope = inner_scope,
    };
}

fn createExprWithSourceRange(ps: *ParseState, source_range: SourceRange, inner: ExpressionInner) !*const Expression {
    const expr = try ps.arena_allocator.create(Expression);
    expr.* = .{
        .source_range = source_range,
        .inner = inner,
    };
    return expr;
}

fn createExpr(ps: *ParseState, loc0: SourceLocation, inner: ExpressionInner) !*const Expression {
    // you pass the location of the start of the expression. this function will use the tokenizer's
    // current location to set the expression's end location
    return createExprWithSourceRange(ps, .{ .loc0 = loc0, .loc1 = ps.tokenizer.loc }, inner);
}

fn findLocal(ps_mod: *ParseModuleState, scope: *const Scope, name: []const u8) ?usize {
    var maybe_s: ?*const Scope = scope;
    while (maybe_s) |sc| : (maybe_s = sc.parent) {
        for (sc.statements.items) |statement| {
            switch (statement) {
                .let_assignment => |x| {
                    if (std.mem.eql(u8, ps_mod.locals.items[x.local_index].name, name)) {
                        return x.local_index;
                    }
                },
                else => {},
            }
        }
    }
    return null;
}

fn findParam(ps_mod: *ParseModuleState, name: []const u8) ?usize {
    for (ps_mod.params) |param, i| {
        if (std.mem.eql(u8, param.name, name)) {
            return i;
        }
    }
    return null;
}

fn requireLocalOrParam(ps: *ParseState, ps_mod: *ParseModuleState, scope: *const Scope, name_source_range: SourceRange) !ExpressionInner {
    const name = ps.tokenizer.source.getString(name_source_range);
    if (findLocal(ps_mod, scope, name)) |local_index| {
        return ExpressionInner{ .local = local_index };
    }
    if (findParam(ps_mod, name)) |param_index| {
        return ExpressionInner{ .self_param = param_index };
    }
    return fail(ps.tokenizer.source, name_source_range, "no local or param called `<`", .{});
}

const BinaryOperator = struct {
    symbol: TokenType,
    priority: usize,
    op: BinArithOp,
};

const binary_operators = [_]BinaryOperator{
    .{ .symbol = .sym_plus, .priority = 1, .op = .add },
    .{ .symbol = .sym_minus, .priority = 1, .op = .sub },
    .{ .symbol = .sym_asterisk, .priority = 2, .op = .mul },
    .{ .symbol = .sym_slash, .priority = 2, .op = .div },
};

fn expectExpression(ps: *ParseState, ps_mod: *ParseModuleState, scope: *const Scope) ParseError!*const Expression {
    return expectExpression2(ps, ps_mod, scope, 0);
}

fn expectExpression2(ps: *ParseState, ps_mod: *ParseModuleState, scope: *const Scope, priority: usize) ParseError!*const Expression {
    var negate = false;
    const peeked_token = try ps.tokenizer.peek();
    if (peeked_token.tt == .sym_minus) {
        _ = try ps.tokenizer.next(); // skip the peeked token
        negate = true;
    }

    var a = try expectTerm(ps, ps_mod, scope);
    const loc0 = a.source_range.loc0;

    if (negate) {
        a = try createExpr(ps, loc0, .{ .un_arith = .{ .op = .neg, .a = a } });
    }

    while (true) {
        const token = try ps.tokenizer.peek();
        for (binary_operators) |bo| {
            const T = @TagType(TokenType);
            if (@as(T, token.tt) == @as(T, bo.symbol) and priority < bo.priority) {
                _ = try ps.tokenizer.next(); // skip the peeked token
                const b = try expectExpression2(ps, ps_mod, scope, bo.priority);
                a = try createExpr(ps, loc0, .{ .bin_arith = .{ .op = bo.op, .a = a, .b = b } });
                break;
            }
        } else {
            break;
        }
    }

    return a;
}

fn parseUnaryFunction(ps: *ParseState, ps_mod: *ParseModuleState, scope: *const Scope, loc0: SourceLocation, op: UnArithOp) !*const Expression {
    try ps.tokenizer.expectNext(.sym_left_paren);
    const a = try expectExpression(ps, ps_mod, scope);
    try ps.tokenizer.expectNext(.sym_right_paren);
    return try createExpr(ps, loc0, .{ .un_arith = .{ .op = op, .a = a } });
}

fn parseBinaryFunction(ps: *ParseState, ps_mod: *ParseModuleState, scope: *const Scope, loc0: SourceLocation, op: BinArithOp) !*const Expression {
    try ps.tokenizer.expectNext(.sym_left_paren);
    const a = try expectExpression(ps, ps_mod, scope);
    try ps.tokenizer.expectNext(.sym_comma);
    const b = try expectExpression(ps, ps_mod, scope);
    try ps.tokenizer.expectNext(.sym_right_paren);
    return try createExpr(ps, loc0, .{ .bin_arith = .{ .op = op, .a = a, .b = b } });
}

fn expectTerm(ps: *ParseState, ps_mod: *ParseModuleState, scope: *const Scope) ParseError!*const Expression {
    const token = try ps.tokenizer.next();
    const loc0 = token.source_range.loc0;

    switch (token.tt) {
        .sym_left_paren => {
            const a = try expectExpression(ps, ps_mod, scope);
            try ps.tokenizer.expectNext(.sym_right_paren);
            return a;
        },
        .uppercase_name => {
            const s = ps.tokenizer.source.getString(token.source_range);
            const call = try parseCall(ps, ps_mod, scope, token, s);
            return try createExpr(ps, loc0, .{ .call = call });
        },
        .lowercase_name => {
            const s = ps.tokenizer.source.getString(token.source_range);
            // this list of builtins corresponds to the `reserved_names` list
            if (std.mem.eql(u8, s, "abs")) {
                return parseUnaryFunction(ps, ps_mod, scope, loc0, .abs);
            } else if (std.mem.eql(u8, s, "cos")) {
                return parseUnaryFunction(ps, ps_mod, scope, loc0, .cos);
            } else if (std.mem.eql(u8, s, "max")) {
                return parseBinaryFunction(ps, ps_mod, scope, loc0, .max);
            } else if (std.mem.eql(u8, s, "min")) {
                return parseBinaryFunction(ps, ps_mod, scope, loc0, .min);
            } else if (std.mem.eql(u8, s, "pi")) {
                return try createExpr(ps, loc0, .{
                    .literal_number = .{
                        .value = std.math.pi,
                        .verbatim = "std.math.pi",
                    },
                });
            } else if (std.mem.eql(u8, s, "pow")) {
                return parseBinaryFunction(ps, ps_mod, scope, loc0, .pow);
            } else if (std.mem.eql(u8, s, "sin")) {
                return parseUnaryFunction(ps, ps_mod, scope, loc0, .sin);
            } else if (std.mem.eql(u8, s, "sqrt")) {
                return parseUnaryFunction(ps, ps_mod, scope, loc0, .sqrt);
            } else {
                const inner = try requireLocalOrParam(ps, ps_mod, scope, token.source_range);
                return try createExpr(ps, loc0, inner);
            }
        },
        .kw_false => {
            return try createExpr(ps, loc0, .{ .literal_boolean = false });
        },
        .kw_true => {
            return try createExpr(ps, loc0, .{ .literal_boolean = true });
        },
        .number => |n| {
            return try createExpr(ps, loc0, .{
                .literal_number = .{
                    .value = n,
                    .verbatim = ps.tokenizer.source.getString(token.source_range),
                },
            });
        },
        .enum_value => {
            const s = ps.tokenizer.source.getString(token.source_range);
            const peeked_token = try ps.tokenizer.peek();
            if (peeked_token.tt == .sym_left_paren) {
                _ = try ps.tokenizer.next();
                const payload = try expectExpression(ps, ps_mod, scope);
                try ps.tokenizer.expectNext(.sym_right_paren);

                const enum_literal: EnumLiteral = .{ .label = s, .payload = payload };
                return try createExpr(ps, loc0, .{ .literal_enum_value = enum_literal });
            } else {
                const enum_literal: EnumLiteral = .{ .label = s, .payload = null };
                return try createExprWithSourceRange(ps, token.source_range, .{ .literal_enum_value = enum_literal });
            }
        },
        .kw_delay => {
            const delay = try parseDelay(ps, ps_mod, scope);
            return try createExpr(ps, loc0, .{ .delay = delay });
        },
        .kw_feedback => {
            return try createExpr(ps, loc0, .feedback);
        },
        else => return ps.tokenizer.failExpected("expression", token),
    }
}

fn parseLocalDecl(ps: *ParseState, ps_mod: *ParseModuleState, scope: *Scope, name_token: Token) !void {
    const name = ps.tokenizer.source.getString(name_token.source_range);
    try ps.tokenizer.expectNext(.sym_equals);
    for (reserved_names) |reserved_name| {
        if (std.mem.eql(u8, name, reserved_name)) {
            return fail(ps.tokenizer.source, name_token.source_range, "`<` is a reserved name", .{});
        }
    }
    // locals are allowed to shadow params, but not other locals
    if (findLocal(ps_mod, scope, name) != null) {
        return fail(ps.tokenizer.source, name_token.source_range, "redeclaration of local `<`", .{});
    }
    const expr = try expectExpression(ps, ps_mod, scope);
    const local_index = ps_mod.locals.items.len;
    try ps_mod.locals.append(.{
        .name = name,
    });
    try scope.statements.append(.{
        .let_assignment = .{
            .local_index = local_index,
            .expression = expr,
        },
    });
}

fn parseStatements(ps: *ParseState, ps_mod: *ParseModuleState, parent_scope: ?*const Scope) !*Scope {
    var scope = try ps.arena_allocator.create(Scope);
    scope.* = .{
        .parent = parent_scope,
        .statements = std.ArrayList(Statement).init(ps.arena_allocator),
    };

    while (true) {
        const token = try ps.tokenizer.next();
        switch (token.tt) {
            .kw_end => break,
            .lowercase_name => {
                try parseLocalDecl(ps, ps_mod, scope, token);
            },
            .kw_out => {
                const expr = try expectExpression(ps, ps_mod, scope);
                try scope.statements.append(.{ .output = expr });
            },
            .kw_feedback => {
                const expr = try expectExpression(ps, ps_mod, scope);
                try scope.statements.append(.{ .feedback = expr });
            },
            else => return ps.tokenizer.failExpected("local declaration, `out`, `feedback` or `end`", token),
        }
    }

    return scope;
}

pub const ParseResult = struct {
    arena: std.heap.ArenaAllocator,
    modules: []const Module,

    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
    }
};

pub fn parse(
    source: Source,
    comptime builtin_packages: []const BuiltinPackage,
    inner_allocator: *std.mem.Allocator,
) !ParseResult {
    var arena = std.heap.ArenaAllocator.init(inner_allocator);
    errdefer arena.deinit();

    var ps: ParseState = .{
        .arena_allocator = &arena.allocator,
        .tokenizer = Tokenizer.init(source),
        .enums = std.ArrayList(BuiltinEnum).init(&arena.allocator),
        .modules = std.ArrayList(Module).init(&arena.allocator),
    };

    // add builtins
    inline for (builtin_packages) |pkg| {
        try ps.enums.appendSlice(pkg.enums);
        inline for (pkg.builtins) |builtin| {
            try ps.modules.append(.{
                .name = builtin.name,
                .zig_package_name = pkg.zig_package_name,
                .params = builtin.params,
                .info = null,
            });
        }
    }

    // parse the file
    while (true) {
        const token = try ps.tokenizer.next();
        switch (token.tt) {
            .end_of_file => break,
            .kw_def => {
                try defineModule(&ps);
            },
            else => return ps.tokenizer.failExpected("`def` or end of file", token),
        }
    }

    const modules = ps.modules.toOwnedSlice();

    // diagnostic print
    for (modules) |module| {
        parsePrintModule(source, modules, module) catch |err| std.debug.warn("parsePrintModule failed: {}\n", .{err});
    }

    return ParseResult{
        .arena = arena,
        .modules = modules,
    };
}
