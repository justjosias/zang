const std = @import("std");
const PrintHelper = @import("print_helper.zig").PrintHelper;
const Module = @import("parse.zig").Module;
const ModuleField = @import("parse1zig").ModuleField;
const ParsedModuleInfo = @import("parse.zig").ParsedModuleInfo;
const Expression = @import("parse.zig").Expression;
const Statement = @import("parse.zig").Statement;
const Field = @import("parse.zig").Field;
const Local = @import("parse.zig").Local;
const Scope = @import("parse.zig").Scope;

const State = struct {
    modules: []const Module,
    module: Module,
    module_info: ParsedModuleInfo,
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
                try self.print("LET {str} =\n", .{self.module_info.locals[x.local_index].name});
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
                const field = self.module_info.fields[call.field_index];
                const callee_module = self.modules[field.resolved_module_index];
                try self.print("call self.#{usize}({str}) (\n", .{ call.field_index, callee_module.name });
                for (call.args) |arg| {
                    try self.indent(indentation + 1);
                    try self.print("{str}:\n", .{arg.param_name});
                    try self.printExpression(arg.value, indentation + 2);
                }
                try self.indent(indentation);
                try self.print(")\n", .{});
            },
            .local => |local_index| try self.print("{str}\n", .{self.module_info.locals[local_index].name}),
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
            .literal_number => |v| try self.print("{f32}\n", .{v}),
            .literal_enum_value => |str| try self.print("'{str}'\n", .{str}),
            .self_param => |param_index| try self.print("params.{str}\n", .{self.module.params[param_index].name}),
            .negate => |expr| {
                try self.print("negate\n", .{});
                try self.printExpression(expr, indentation + 1);
            },
            .bin_arith => |m| {
                try self.print("{auto}\n", .{m.op});
                try self.printExpression(m.a, indentation + 1);
                try self.printExpression(m.b, indentation + 1);
            },
        }
    }
};

pub fn parsePrintModule(modules: []const Module, module: Module, module_info: ParsedModuleInfo) !void {
    const stderr_file = std.io.getStdErr();
    var stderr_file_out_stream = stderr_file.outStream();

    var self: State = .{
        .modules = modules,
        .module = module,
        .module_info = module_info,
        .helper = PrintHelper.init(&stderr_file_out_stream),
    };
    defer self.helper.deinit();

    try self.print("module '{str}'\n", .{module.name});
    for (module_info.fields) |field, i| {
        const callee_module = modules[field.resolved_module_index];
        try self.print("    field #{usize}({str})\n", .{ i, callee_module.name });
    }
    try self.print("statements:\n", .{});
    for (module_info.scope.statements.items) |statement| {
        try self.printStatement(statement, 1);
    }
    try self.print("\n", .{});
}
