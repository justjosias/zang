const std = @import("std");
const zangscript = @import("zangscript");

// parse a zig file at runtime looking for builtin module definitions
const BuiltinParser = struct {
    arena_allocator: *std.mem.Allocator,
    contents: []const u8,
    tree: *std.zig.ast.Tree,

    fn getToken(self: BuiltinParser, token_index: usize) []const u8 {
        const token = self.tree.tokens.at(token_index);
        return self.contents[token.start..token.end];
    }

    fn parseIntLiteral(self: BuiltinParser, var_decl: *const std.zig.ast.Node.VarDecl) ?usize {
        const init_node = var_decl.init_node orelse return null;
        const lit = init_node.cast(std.zig.ast.Node.IntegerLiteral) orelse return null;
        return std.fmt.parseInt(usize, self.getToken(lit.token), 10) catch return null;
    }

    // `one_of` (enums) not supported
    fn parseParamType(self: BuiltinParser, type_expr: *std.zig.ast.Node) ?zangscript.ParamType {
        if (type_expr.cast(std.zig.ast.Node.Identifier)) |identifier| {
            const type_name = self.getToken(identifier.token);
            if (std.mem.eql(u8, type_name, "bool")) {
                return .boolean;
            }
            if (std.mem.eql(u8, type_name, "f32")) {
                return .constant;
            }
        } else if (type_expr.cast(std.zig.ast.Node.PrefixOp)) |prefix_op| {
            switch (prefix_op.op) {
                .SliceType => |st| {
                    if (st.const_token != null and st.allowzero_token == null and st.sentinel == null) {
                        if (prefix_op.rhs.cast(std.zig.ast.Node.Identifier)) |rhs_identifier| {
                            const type_name = self.getToken(rhs_identifier.token);
                            if (std.mem.eql(u8, type_name, "f32")) {
                                return .buffer;
                            }
                        }
                    }
                },
                else => {},
            }
        } else if (type_expr.cast(std.zig.ast.Node.InfixOp)) |infix_op| {
            if (infix_op.lhs.cast(std.zig.ast.Node.Identifier)) |lhs_identifier| {
                if (std.mem.eql(u8, self.getToken(lhs_identifier.token), "zang") and infix_op.op == .Period) {
                    if (infix_op.rhs.cast(std.zig.ast.Node.Identifier)) |rhs_identifier| {
                        if (std.mem.eql(u8, self.getToken(rhs_identifier.token), "ConstantOrBuffer")) {
                            return .constant_or_buffer;
                        }
                    }
                }
            }
        }
        return null;
    }

    fn parseParams(self: BuiltinParser, stderr: *std.fs.File.OutStream, var_decl: *const std.zig.ast.Node.VarDecl) ![]const zangscript.ModuleParam {
        const init_node = var_decl.init_node orelse {
            try stderr.print("expected init node\n", .{});
            return error.Failed;
        };
        const container_decl = init_node.cast(std.zig.ast.Node.ContainerDecl) orelse {
            try stderr.print("expected container decl\n", .{});
            return error.Failed;
        };

        var params = std.ArrayList(zangscript.ModuleParam).init(self.arena_allocator);

        var it = container_decl.fields_and_decls.iterator(0);
        while (it.next()) |node_ptr| {
            const field = node_ptr.*.cast(std.zig.ast.Node.ContainerField) orelse continue;
            const name = self.getToken(field.name_token);
            const type_expr = field.type_expr orelse {
                try stderr.print("expected type expr\n", .{});
                return error.Failed;
            };
            const param_type = self.parseParamType(type_expr) orelse {
                try stderr.print("{}: unrecognized param type\n", .{name});
                return error.Failed;
            };
            try params.append(.{
                .name = try std.mem.dupe(self.arena_allocator, u8, name),
                .param_type = param_type,
            });
        }

        return params.items;
    }

    fn parseTopLevelDecl(self: BuiltinParser, stderr: *std.fs.File.OutStream, var_decl: *std.zig.ast.Node.VarDecl) !?zangscript.BuiltinModule {
        // TODO check for `pub`, and initial uppercase
        const init_node = var_decl.init_node orelse return null;
        const container_decl = init_node.cast(std.zig.ast.Node.ContainerDecl) orelse return null;

        const name = self.getToken(var_decl.name_token);

        var num_outputs: ?usize = null;
        var num_temps: ?usize = null;
        var params: ?[]const zangscript.ModuleParam = null;

        var it = container_decl.fields_and_decls.iterator(0);
        while (it.next()) |node_ptr| {
            const var_decl2 = node_ptr.*.cast(std.zig.ast.Node.VarDecl) orelse continue;
            const name2 = self.getToken(var_decl2.name_token);
            if (std.mem.eql(u8, name2, "num_outputs")) {
                num_outputs = self.parseIntLiteral(var_decl2) orelse {
                    try stderr.print("num_outputs: expected an integer literal\n", .{});
                    return error.Failed;
                };
            }
            if (std.mem.eql(u8, name2, "num_temps")) {
                num_temps = self.parseIntLiteral(var_decl2) orelse {
                    try stderr.print("num_temps: expected an integer literal\n", .{});
                    return error.Failed;
                };
            }
            if (std.mem.eql(u8, name2, "Params")) {
                params = try self.parseParams(stderr, var_decl2);
            }
        }

        return zangscript.BuiltinModule{
            .name = try std.mem.dupe(self.arena_allocator, u8, name),
            .params = params orelse return null,
            .num_temps = num_temps orelse return null,
            .num_outputs = num_outputs orelse return null,
        };
    }
};

pub fn parseBuiltins(
    arena_allocator: *std.mem.Allocator,
    temp_allocator: *std.mem.Allocator,
    stderr: *std.fs.File.OutStream,
    name: []const u8,
    filename: []const u8,
    contents: []const u8,
) !zangscript.BuiltinPackage {
    var builtins = std.ArrayList(zangscript.BuiltinModule).init(arena_allocator);
    var enums = std.ArrayList(zangscript.BuiltinEnum).init(arena_allocator);

    const tree = std.zig.parse(temp_allocator, contents) catch |err| {
        try stderr.print("failed to parse {}: {}\n", .{ filename, err });
        return error.Failed;
    };
    defer tree.deinit();

    if (tree.errors.count() > 0) {
        try stderr.print("parse error in {}\n", .{filename});
        var it = tree.errors.iterator(0);
        while (it.next()) |err| {
            const token = tree.tokens.at(err.loc());
            var line: usize = 1;
            var col: usize = 1;
            for (contents[0..token.start]) |ch| {
                if (ch == '\n') {
                    line += 1;
                    col = 1;
                } else {
                    col += 1;
                }
            }
            try stderr.print("(line {}, col {}) ", .{ line, col });
            try err.render(&tree.tokens, stderr);
            try stderr.writeAll("\n");
        }
        return error.Failed;
    }

    var bp: BuiltinParser = .{
        .arena_allocator = arena_allocator,
        .contents = contents,
        .tree = tree,
    };

    var it = tree.root_node.decls.iterator(0);
    while (it.next()) |node_ptr| {
        const var_decl = node_ptr.*.cast(std.zig.ast.Node.VarDecl) orelse continue;
        if (try bp.parseTopLevelDecl(stderr, var_decl)) |builtin| {
            try builtins.append(builtin);
        }
    }

    return zangscript.BuiltinPackage{
        .zig_package_name = name,
        .zig_import_path = filename,
        .builtins = builtins.items,
        .enums = enums.items,
    };
}
