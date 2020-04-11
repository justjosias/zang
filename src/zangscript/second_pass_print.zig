const std = @import("std");
const FirstPassResult = @import("first_pass.zig").FirstPassResult;
const Module = @import("first_pass.zig").Module;
const ModuleField = @import("first_pass.zig").ModuleField;
const Expression = @import("second_pass.zig").Expression;
const Statement = @import("second_pass.zig").Statement;
const Field = @import("second_pass.zig").Field;
const Local = @import("second_pass.zig").Local;
const Scope = @import("second_pass.zig").Scope;

pub fn secondPassPrintModule(first_pass_result: FirstPassResult, module: Module, fields: []const Field, locals: []const Local, scope: *const Scope, indentation: usize) void {
    std.debug.warn("module '{}'\n", .{module.name});
    for (fields) |field, i| {
        const callee_module = first_pass_result.modules[field.resolved_module_index];
        std.debug.warn("    field #{}({})\n", .{ i, callee_module.name });
    }
    std.debug.warn("statements:\n", .{});
    for (scope.statements.span()) |statement| {
        printStatement(first_pass_result, module, fields, locals, statement, 1);
    }
    std.debug.warn("\n", .{});
}

fn printStatement(first_pass_result: FirstPassResult, module: Module, fields: []const Field, locals: []const Local, statement: Statement, indentation: usize) void {
    var i: usize = 0;
    while (i < indentation) : (i += 1) {
        std.debug.warn("    ", .{});
    }
    switch (statement) {
        .let_assignment => |x| {
            const local = locals[x.local_index];
            std.debug.warn("LET {} =\n", .{local.name});
            printExpression(first_pass_result, module, fields, locals, x.expression, indentation + 1);
        },
        .output => |expression| {
            std.debug.warn("OUT\n", .{});
            printExpression(first_pass_result, module, fields, locals, expression, indentation + 1);
        },
        .feedback => |expression| {
            std.debug.warn("FEEDBACK\n", .{});
            printExpression(first_pass_result, module, fields, locals, expression, indentation + 1);
        },
    }
}

fn printExpression(first_pass_result: FirstPassResult, module: Module, fields: []const Field, locals: []const Local, expression: *const Expression, indentation: usize) void {
    var i: usize = 0;
    while (i < indentation) : (i += 1) {
        std.debug.warn("    ", .{});
    }
    switch (expression.inner) {
        .call => |call| {
            const field = fields[call.field_index];
            const callee_module = first_pass_result.modules[field.resolved_module_index];
            std.debug.warn("call self.#{}({}) (\n", .{ call.field_index, callee_module.name });
            for (call.args) |arg| {
                i = 0;
                while (i < indentation + 1) : (i += 1) {
                    std.debug.warn("    ", .{});
                }
                std.debug.warn("{}:\n", .{arg.param_name});
                printExpression(first_pass_result, module, fields, locals, arg.value, indentation + 2);
            }
            i = 0;
            while (i < indentation) : (i += 1) {
                std.debug.warn("    ", .{});
            }
            std.debug.warn(")\n", .{});
        },
        .local => |local_index| {
            const local = locals[local_index];
            std.debug.warn("{}\n", .{local.name});
        },
        .delay => |delay| {
            std.debug.warn("delay {} (\n", .{delay.num_samples});
            for (delay.scope.statements.span()) |statement| {
                printStatement(first_pass_result, module, fields, locals, statement, indentation + 1);
            }
            i = 0;
            while (i < indentation) : (i += 1) {
                std.debug.warn("    ", .{});
            }
            std.debug.warn(")\n", .{});
        },
        .feedback => {
            std.debug.warn("feedback\n", .{});
        },
        .literal_boolean => |v| std.debug.warn("{}\n", .{v}),
        .literal_number => |v| std.debug.warn("{d}\n", .{v}),
        .literal_enum_value => |str| std.debug.warn("'{}'\n", .{str}),
        .self_param => |param_index| {
            const params = first_pass_result.module_params[module.first_param .. module.first_param + module.num_params];
            std.debug.warn("params.{}\n", .{params[param_index].name});
        },
        .bin_arith => |m| {
            switch (m.op) {
                .add => std.debug.warn("add\n", .{}),
                .mul => std.debug.warn("mul\n", .{}),
                .pow => std.debug.warn("pow\n", .{}),
            }
            printExpression(first_pass_result, module, fields, locals, m.a, indentation + 1);
            printExpression(first_pass_result, module, fields, locals, m.b, indentation + 1);
        },
    }
}
