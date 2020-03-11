const std = @import("std");
const Parser = @import("common.zig").Parser;
const Source = @import("common.zig").Source;
const fail = @import("common.zig").fail;
const Token = @import("tokenizer.zig").Token;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const tokenize = @import("tokenizer.zig").tokenize;
const BuiltinModule = @import("first_pass.zig").BuiltinModule;
const ModuleFieldDecl = @import("first_pass.zig").ModuleFieldDecl;
const ModuleDef = @import("first_pass.zig").ModuleDef;

// this will be a lisp like syntax tree... stuff like order of operations will be applied before we get in here
// then an additional pass will be made to bake this down and get temps
pub const Call = struct {
    field_index: usize, // index of the field in the "self" module
    // TODO args
};

pub const Expression = union(enum) {
    call: Call,
};

fn parseCallArg(self: *Parser, token: Token) !void {
    switch (token.tt) {
        .identifier => |identifier| {
            if (self.peekSymbol(.sym_colon)) {
                var token2 = try self.expect();
                if (token2.tt != .sym_colon) {
                    return fail(self.source, token2, "expected `:`, found `%`", .{token2});
                }
                token2 = try self.expect();
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
                            token2,
                            "expected arg value, found `%`",
                            .{token2},
                        );
                    },
                }
            } else {
                // just a name. my idea is that this is shorthand for
                // `property: params.property` (passing along own param)
                std.debug.warn("    arg {}\n", .{identifier});
            }
        },
        else => {
            return fail(
                self.source,
                token,
                "expected `)` or arg name, found `%`",
                .{token},
            );
        },
    }
}

fn parseCall(self: *Parser, module_def: *ModuleDef) !Call {
    // referencing one of the fields. like a function call
    const name_token = try self.expect();
    const name = switch (name_token.tt) {
        .identifier => |identifier| identifier,
        else => return fail(self.source, name_token, "expected field name, found `%`", .{name_token}),
    };
    const field_index = for (module_def.fields.span()) |*field, i| {
        if (std.mem.eql(u8, field.name, name)) {
            break i;
        }
    } else {
        //return fail(self.source, name_token, "not a field of `#`: `%`", .{ module_def.name, name_token }); // FIXME not working?
        return fail(self.source, name_token, "not a field of self: `%`", .{name_token});
    };
    std.debug.warn("  calling {}\n", .{name});
    // arguments
    var token = try self.expect();
    if (token.tt != .sym_left_paren) {
        return fail(self.source, token, "expected `(`, found `%`", .{token});
    }
    var first = true;
    while (true) {
        token = try self.expect();
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
                    token,
                    "expected `,` or `)`, found `%`",
                    .{token},
                );
            }
        }
        try parseCallArg(self, token);
    }
    return Call{
        .field_index = field_index,
    };
}

fn paintBlock(
    source: Source,
    tokens: []const Token,
    module_def: *ModuleDef,
) !Expression {
    var self: Parser = .{
        .source = source,
        .tokens = tokens[module_def.begin_token..module_def.end_token],
        .i = 0,
    };

    while (true) {
        const token = try self.expect();
        switch (token.tt) {
            .kw_end => break,
            .sym_at => {
                const call = try parseCall(&self, module_def);
                return Expression{ .call = call };
            },
            else => {
                return fail(
                    source,
                    token,
                    "expected `@` or `end`, found `%`",
                    .{token},
                );
            },
        }
    }

    return fail(source, null, "?", .{}); // FIXME
}

pub fn secondPass(
    source: Source,
    tokens: []const Token,
    module_defs: []ModuleDef,
) !void {
    for (module_defs) |*module_def| {
        std.debug.warn("module '{}'\n", .{module_def.name});
        for (module_def.fields.span()) |field| {
            std.debug.warn("field {}: {}\n", .{ field.name, field.type_name });
        }

        module_def.expression = try paintBlock(source, tokens, module_def);
    }
}
