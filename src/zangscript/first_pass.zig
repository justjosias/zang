const std = @import("std");
const Parser = @import("common.zig").Parser;
const Source = @import("common.zig").Source;
const fail = @import("common.zig").fail;
const Token = @import("tokenizer.zig").Token;
const TokenType = @import("tokenizer.zig").TokenType;
const SourceLocation = @import("tokenizer.zig").SourceLocation;

pub const ModuleFieldDecl = struct {
    name: []const u8,
    type_name: []const u8,
};

pub const ModuleDef = struct {
    name: []const u8,
    fields: std.ArrayList(ModuleFieldDecl),
    begin_token: usize,
    end_token: usize,
};

pub const FirstPassResult = struct {
    module_defs: []ModuleDef,
};

pub const FirstPass = struct {
    parser: Parser,
    module_defs: std.ArrayList(ModuleDef),

    pub fn init(
        source: Source,
        tokens: []const Token,
        allocator: *std.mem.Allocator,
    ) FirstPass {
        return .{
            .parser = .{
                .source = source,
                .tokens = tokens,
                .i = 0,
            },
            .module_defs = std.ArrayList(ModuleDef).init(allocator),
        };
    }
};

pub fn defineModule(self: *FirstPass, allocator: *std.mem.Allocator) !void {
    const module_name = try self.parser.expectIdentifier();
    try self.parser.expectSymbol(.sym_colon);

    var module_def: ModuleDef = .{
        .name = module_name,
        .fields = std.ArrayList(ModuleFieldDecl).init(allocator),
        .begin_token = undefined,
        .end_token = undefined,
    };

    while (true) {
        const token = try self.parser.expect();
        switch (token.tt) {
            .kw_begin => break,
            .identifier => |identifier| {
                // field declaration
                const field_name = identifier;
                const field_type = try self.parser.expectIdentifier();
                try self.parser.expectSymbol(.sym_semicolon);
                try module_def.fields.append(.{
                    .name = field_name,
                    .type_name = field_type,
                });
                continue;
            },
            else => {
                return fail(
                    self.parser.source,
                    token.loc,
                    "expected field declaration or `begin`, found `%`",
                    .{ token.tt },
                );
            },
        }
    }

    // skip paint block
    module_def.begin_token = self.parser.i;
    while (true) {
        const token = try self.parser.expect();
        switch (token.tt) {
            .kw_end => break,
            else => {},
        }
    }
    module_def.end_token = self.parser.i;

    try self.module_defs.append(module_def);
}

pub fn firstPass(
    source: Source,
    tokens: []const Token,
    allocator: *std.mem.Allocator,
) !FirstPassResult {
    var self = FirstPass.init(source, tokens, allocator);

    errdefer {
        // FIXME deinit fields
        self.module_defs.deinit();
    }

    while (self.parser.next()) |token| {
        switch (token.tt) {
            .kw_def => try defineModule(&self, allocator),
            else => {
                return fail(
                    self.parser.source,
                    token.loc,
                    "expected `def` or end of file, found `%`",
                    .{ token.tt },
                );
            },
        }
    }

    return FirstPassResult {
        .module_defs = self.module_defs.toOwnedSlice(),
    };
}
