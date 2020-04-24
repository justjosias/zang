const std = @import("std");
const Source = @import("tokenize.zig").Source;
const SourceLocation = @import("tokenize.zig").SourceLocation;
const SourceRange = @import("tokenize.zig").SourceRange;
const Token = @import("tokenize.zig").Token;
const TokenType = @import("tokenize.zig").TokenType;
const TokenIterator = @import("tokenize.zig").TokenIterator;
const fail = @import("fail.zig").fail;
const BuiltinPackage = @import("builtins.zig").BuiltinPackage;
const parsePrintModule = @import("parse_print.zig").parsePrintModule;

pub const ParamTypeEnum = struct {
    zig_name: []const u8,
    values: []const []const u8,
};

pub const ParamType = union(enum) {
    boolean,
    buffer,
    constant,
    constant_or_buffer,

    // currently only builtin modules can define enum params
    one_of: ParamTypeEnum,
};

pub const ModuleParam = struct {
    name: []const u8,
    param_type: ParamType,
};

pub const Field = struct {
    type_token: Token,
    resolved_module_index: usize,
};

pub const ParsedModuleInfo = struct {
    scope: *Scope,
    fields: []const Field,
    locals: []const Local,
};

pub const Module = struct {
    name: []const u8,
    zig_package_name: ?[]const u8, // only set for builtin modules
    params: []const ModuleParam,
    // FIXME - i wanted body_loc to be an optional struct value, but a zig
    // compiler bug prevents that. (if i make it optional, the fields will read
    // out as all 0's in the second pass)
    has_body_loc: bool,
    // the following will both be zero for builtin modules (has_body_loc is
    // false)
    begin_token: usize,
    end_token: usize,
    // info: null for builtins
    info: ?ParsedModuleInfo,
};

const FirstPass = struct {
    arena_allocator: *std.mem.Allocator,
    token_it: TokenIterator,
    modules: std.ArrayList(Module),
};

fn expectParamType(self: *FirstPass) !ParamType {
    const type_token = try self.token_it.expectIdentifier("param type");
    const type_name = self.token_it.getSourceString(type_token.source_range);
    if (std.mem.eql(u8, type_name, "boolean")) {
        return .boolean;
    }
    if (std.mem.eql(u8, type_name, "constant")) {
        return .constant;
    }
    if (std.mem.eql(u8, type_name, "waveform")) {
        return .buffer;
    }
    if (std.mem.eql(u8, type_name, "cob")) {
        return .constant_or_buffer;
    }
    return self.token_it.failExpected("param_type", type_token.source_range);
}

fn defineModule(self: *FirstPass) !void {
    const module_name_token = try self.token_it.expectIdentifier("module name");
    const module_name = self.token_it.getSourceString(module_name_token.source_range);
    if (module_name[0] < 'A' or module_name[0] > 'Z') {
        return fail(self.token_it.source, module_name_token.source_range, "module name must start with a capital letter", .{});
    }
    _ = try self.token_it.expectOneOf(&[_]TokenType{.sym_colon});

    var params = std.ArrayList(ModuleParam).init(self.arena_allocator);

    while (true) {
        const token = try self.token_it.expectOneOf(&[_]TokenType{ .kw_begin, .identifier });
        switch (token.tt) {
            else => unreachable,
            .kw_begin => break,
            .identifier => {
                // param declaration
                const param_name = self.token_it.getSourceString(token.source_range);
                if (param_name[0] < 'a' or param_name[0] > 'z') {
                    return fail(self.token_it.source, token.source_range, "param name must start with a lowercase letter", .{});
                }
                for (params.items) |param| {
                    if (std.mem.eql(u8, param.name, param_name)) {
                        return fail(self.token_it.source, token.source_range, "redeclaration of param `<`", .{});
                    }
                }
                _ = try self.token_it.expectOneOf(&[_]TokenType{.sym_colon});
                const param_type = try expectParamType(self);
                _ = try self.token_it.expectOneOf(&[_]TokenType{.sym_comma});
                try params.append(.{
                    .name = param_name,
                    .param_type = param_type,
                });
            },
        }
    }

    // skip paint block
    const begin_token = self.token_it.i;
    var num_inner_blocks: usize = 0; // "delay" ops use inner blocks
    while (true) {
        const token = try self.token_it.expect("`end`");
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
    const end_token = self.token_it.i;

    try self.modules.append(.{
        .name = module_name,
        .zig_package_name = null,
        .params = params.toOwnedSlice(),
        .has_body_loc = true,
        .begin_token = begin_token,
        .end_token = end_token,
        .info = null, // this will get filled in later
    });
}

//////////////////////////// SECOND PASS

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

pub const UnresolvedField = struct {
    type_token: Token,
};

const SecondPass = struct {
    arena_allocator: *std.mem.Allocator,
    tokens: []const Token,
    token_it: TokenIterator,
    modules: []const Module,
    module: Module,
    module_index: usize,
    fields: std.ArrayList(UnresolvedField),
    locals: std.ArrayList(Local),
};

const ParseError = error{
    Failed,
    OutOfMemory,
};

fn parseCall(self: *SecondPass, scope: *const Scope, field_name_token: Token, field_name: []const u8) ParseError!Call {
    // add a field
    const field_index = self.fields.items.len;
    try self.fields.append(.{
        .type_token = field_name_token,
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

pub const ParseResult = struct {
    arena: std.heap.ArenaAllocator,
    builtin_packages: []const BuiltinPackage,
    modules: []const Module,

    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
    }
};

pub fn parse(
    source: Source,
    tokens: []const Token,
    builtin_packages: []const BuiltinPackage,
    inner_allocator: *std.mem.Allocator,
) !ParseResult {
    var arena = std.heap.ArenaAllocator.init(inner_allocator);
    errdefer arena.deinit();

    // first pass: parse top level, skipping over module implementations
    var first_pass: FirstPass = .{
        .arena_allocator = &arena.allocator,
        .token_it = TokenIterator.init(source, tokens),
        .modules = std.ArrayList(Module).init(&arena.allocator),
    };

    // add builtins
    for (builtin_packages) |pkg| {
        for (pkg.builtins) |builtin| {
            try first_pass.modules.append(.{
                .name = builtin.name,
                .zig_package_name = pkg.zig_package_name,
                .params = builtin.params,
                .has_body_loc = false,
                .begin_token = 0,
                .end_token = 0,
                .info = null,
            });
        }
    }

    // parse module declarations, including param declarations, but skipping over the paint blocks
    while (first_pass.token_it.next()) |token| {
        switch (token.tt) {
            .kw_def => try defineModule(&first_pass),
            else => return first_pass.token_it.failExpected("`def` or end of file", token.source_range),
        }
    }

    const modules = first_pass.modules.toOwnedSlice();

    // second pass: parse each module's paint block
    const SecondPassResult = struct {
        scope: *Scope,
        fields: []const UnresolvedField,
        locals: []const Local,
    };

    var results = try inner_allocator.alloc(?SecondPassResult, modules.len);
    defer inner_allocator.free(results);

    for (modules) |module, module_index| {
        if (!module.has_body_loc) {
            // it's a builtin
            results[module_index] = null;
            continue;
        }

        var self: SecondPass = .{
            .arena_allocator = &arena.allocator,
            .tokens = tokens,
            .token_it = TokenIterator.init(source, tokens[module.begin_token..module.end_token]),
            .modules = modules,
            .module = module,
            .module_index = module_index,
            .fields = std.ArrayList(UnresolvedField).init(&arena.allocator),
            .locals = std.ArrayList(Local).init(&arena.allocator),
        };

        const top_scope = try parseStatements(&self, null);

        results[module_index] = SecondPassResult{
            .scope = top_scope,
            .fields = self.fields.toOwnedSlice(),
            .locals = self.locals.toOwnedSlice(),
        };
    }

    // kind of a third pass: resolve fields
    // now that i've added this, the first and second passes can actually be combined. (TODO)
    for (results) |maybe_result, module_index| {
        const result = maybe_result orelse {
            modules[module_index].info = null; // actually this was already null
            continue;
        };
        var resolved_fields = try arena.allocator.alloc(Field, result.fields.len);
        for (result.fields) |field, field_index| {
            const field_name = source.getString(field.type_token.source_range);
            const callee_module_index = for (modules) |module, i| {
                if (std.mem.eql(u8, field_name, module.name)) {
                    break i;
                }
            } else {
                return fail(source, field.type_token.source_range, "no module called `<`", .{});
            };
            resolved_fields[field_index] = .{
                .type_token = field.type_token,
                .resolved_module_index = callee_module_index,
            };
        }
        modules[module_index].info = ParsedModuleInfo{
            .scope = result.scope,
            .fields = resolved_fields,
            .locals = result.locals,
        };
    }

    // diagnostic print
    for (modules) |module| {
        parsePrintModule(modules, module) catch |err| std.debug.warn("parsePrintModule failed: {}\n", .{err});
    }

    return ParseResult{
        .arena = arena,
        .builtin_packages = builtin_packages,
        .modules = modules,
    };
}
