const std = @import("std");
const Source = @import("context.zig").Source;
const PrintHelper = @import("print_helper.zig").PrintHelper;
const Module = @import("parse.zig").Module;
const ModuleField = @import("parse1zig").ModuleField;
const Expression = @import("parse.zig").Expression;
const Statement = @import("parse.zig").Statement;
const Field = @import("parse.zig").Field;
const Local = @import("parse.zig").Local;
const Scope = @import("parse.zig").Scope;

const State = struct {
    source: Source,
    modules: []const Module,
    module: Module,
    helper: PrintHelper,

    pub fn print(self: *State, comptime fmt: []const u8, args: var) !void {
        try self.helper.print(self, fmt, args);
    }

    pub fn printArgValue(self: *State, comptime arg_format: []const u8, arg: var) !void {
        @compileError("unknown arg_format: \"" ++ arg_format ++ "\"");
    }

    fn indent(self: *State, indentation: usize) !void {
        var i: usize = 0;
        while (i < indentation) : (i += 1) {
            try self.print("    ", .{});
        }
    }

    fn printStatement(self: *State, statement: Statement, indentation: usize) !void {
        try self.indent(indentation);
        switch (statement) {
            .let_assignment => |x| {
                try self.print("LET {str} =\n", .{self.module.info.?.locals[x.local_index].name});
                try self.printExpression(x.expression, indentation + 1);
            },
            .output => |expression| {
                try self.print("OUT\n", .{});
                try self.printExpression(expression, indentation + 1);
            },
            .feedback => |expression| {
                try self.print("FEEDBACK\n", .{});
                try self.printExpression(expression, indentation + 1);
            },
        }
    }

    fn printExpression(self: *State, expression: *const Expression, indentation: usize) std.os.WriteError!void {
        try self.indent(indentation);
        switch (expression.inner) {
            .call => |call| {
                const field = self.module.info.?.fields[call.field_index];
                const field_name = self.source.getString(field.type_token.source_range);
                try self.print("call self.#{usize}({str}) (\n", .{ call.field_index, field_name });
                for (call.args) |arg| {
                    try self.indent(indentation + 1);
                    try self.print("{str}:\n", .{arg.param_name});
                    try self.printExpression(arg.value, indentation + 2);
                }
                try self.indent(indentation);
                try self.print(")\n", .{});
            },
            .local => |local_index| try self.print("{str}\n", .{self.module.info.?.locals[local_index].name}),
            .track_call => |track_call| {
                try self.print("track_call @{str} (\n", .{self.source.getString(track_call.track_name_token.source_range)});
                for (track_call.scope.statements.items) |statement| {
                    try self.printStatement(statement, indentation + 1);
                }
                try self.indent(indentation);
                try self.print(")\n", .{});
            },
            .track_param => |token| try self.print("@.{str}\n", .{self.source.getString(token.source_range)}),
            .delay => |delay| {
                try self.print("delay {usize} (\n", .{delay.num_samples});
                for (delay.scope.statements.items) |statement| {
                    try self.printStatement(statement, indentation + 1);
                }
                try self.indent(indentation);
                try self.print(")\n", .{});
            },
            .feedback => try self.print("feedback\n", .{}),
            .literal_boolean => |v| try self.print("{bool}\n", .{v}),
            .literal_number => |v| try self.print("{number_literal}\n", .{v}),
            .literal_enum_value => |v| {
                try self.print("'{str}'\n", .{v.label});
                if (v.payload) |payload| {
                    try self.printExpression(payload, indentation + 1);
                }
            },
            .literal_curve => |curve_index| try self.print("(curve {usize})\n", .{curve_index}),
            .self_param => |param_index| try self.print("params.{str}\n", .{self.module.params[param_index].name}),
            .global => |token| try self.print("(global){str}\n", .{self.source.getString(token.source_range)}),
            .un_arith => |m| {
                try self.print("{auto}\n", .{m.op});
                try self.printExpression(m.a, indentation + 1);
            },
            .bin_arith => |m| {
                try self.print("{auto}\n", .{m.op});
                try self.printExpression(m.a, indentation + 1);
                try self.printExpression(m.b, indentation + 1);
            },
        }
    }
};

pub fn parsePrintModule(out: std.io.StreamSource.OutStream, source: Source, modules: []const Module, module: Module) !void {
    var self: State = .{
        .source = source,
        .modules = modules,
        .module = module,
        .helper = PrintHelper.init(out),
    };

    if (module.info) |info| {
        try self.print("module '{str}'\n", .{module.name});
        for (info.fields) |field, i| {
            const name = source.getString(field.type_token.source_range);
            try self.print("    field #{usize}({str})\n", .{ i, name });
        }
        try self.print("statements:\n", .{});
        for (info.scope.statements.items) |statement| {
            try self.printStatement(statement, 1);
        }
    } else {
        try self.print("builtin module '{str}'\n", .{module.name});
    }
    try self.print("\n", .{});

    self.helper.finish();
}
