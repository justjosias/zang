const std = @import("std");
const Parser = @import("common.zig").Parser;
const Source = @import("common.zig").Source;
const fail = @import("common.zig").fail;
const Token = @import("tokenizer.zig").Token;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const tokenize = @import("tokenizer.zig").tokenize;
const ModuleFieldDecl = @import("first_pass.zig").ModuleFieldDecl;
const ModuleDef = @import("first_pass.zig").ModuleDef;

fn parseCall(self: *Parser) !void {
    // referencing one of the fields. like a function call
    const name = try self.expectIdentifier();
    std.debug.warn("  calling {}\n", .{ name });
    // arguments
    try self.expectSymbol(.sym_left_paren);
    var first = true;
    while (true) {
        var token = try self.expect();
        if (token.tt == .sym_right_paren) {
            std.debug.warn("  done\n", .{});
            break;
        }
        if (first) {
            first = false;
        } else {
            if (token.tt == .sym_comma) {
                token = try self.expect();
            } else {
                return fail(
                    self.source,
                    token.loc,
                    "expected `,` or `)`, found `%`",
                    .{ token.tt },
                );
            }
        }
        switch (token.tt) {
            .identifier => |identifier| {
                if (self.peekSymbol(.sym_colon)) {
                    try self.expectSymbol(.sym_colon);
                    const token2 = try self.expect();
                    switch (token2.tt) {
                        .number => |n| {
                            std.debug.warn("    arg {} = {d}\n", .{
                                identifier,
                                n,
                            });
                        },
                        else => {
                            return fail(
                                self.source,
                                token2.loc,
                                "expected arg value, found `%`",
                                .{ token.tt },
                            );
                        },
                    }
                } else {
                    // just a name. my idea is that this is shorthand for
                    // `property: params.property` (passing along own param)
                    std.debug.warn("    arg {}\n", .{ identifier });
                }
            },
            else => {
                return fail(
                    self.source,
                    token.loc,
                    "expected `)` or arg name, found `%`",
                    .{ token.tt },
                );
            },
        }
    }
}

fn paintBlock(
    source: Source,
    tokens: []const Token,
    module_def: *ModuleDef,
) !void {
    var self: Parser = .{
        .source = source,
        .tokens = tokens[module_def.begin_token..module_def.end_token],
        .i = 0,
    };

    while (true) {
        const token = try self.expect();
        switch (token.tt) {
            .kw_end => break,
            .sym_at => try parseCall(&self),
            else => {
                return fail(
                    source,
                    token.loc,
                    "expected `@` or `end`, found `%`",
                    .{ token.tt },
                );
            },
        }
    }
}

pub fn secondPass(
    source: Source,
    tokens: []const Token,
    module_defs: []ModuleDef,
) !void {
    for (module_defs) |*module_def| {
        std.debug.warn("module '{}'\n", .{ module_def.name });
        for (module_def.fields.span()) |field| {
            std.debug.warn("field {}: {}\n", .{ field.name, field.type_name });
        }

        try paintBlock(source, tokens, module_def);
    }
}
