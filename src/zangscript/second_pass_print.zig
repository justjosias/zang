const std = @import("std");
const FirstPassResult = @import("first_pass.zig").FirstPassResult;
const Module = @import("first_pass.zig").Module;
const ModuleField = @import("first_pass.zig").ModuleField;
const Expression = @import("second_pass.zig").Expression;
const Statement = @import("second_pass.zig").Statement;
const Local = @import("second_pass.zig").Local;
const Scope = @import("second_pass.zig").Scope;

pub fn secondPassPrintModule(first_pass_result: FirstPassResult, module: Module, locals: []const Local, scope: *const Scope, indentation: usize) void {
    const fields = first_pass_result.module_fields[module.first_field .. module.first_field + module.num_fields];

    std.debug.warn("module '{}'\n", .{module.name});
    for (fields) |field| {
        std.debug.warn("    field {}: {}\n", .{ field.name, field.type_name });
    }
    std.debug.warn("statements:\n", .{});
    for (scope.statements.span()) |statement| {
        printStatement(first_pass_result, module, locals, statement, 1);
    }
    std.debug.warn("\n", .{});
}

fn printStatement(first_pass_result: FirstPassResult, module: Module, locals: []const Local, statement: Statement, indentation: usize) void {
    var i: usize = 0;
    while (i < indentation) : (i += 1) {
        std.debug.warn("    ", .{});
    }
    switch (statement) {
        .let_assignment => |x| {
            const local = locals[x.local_index];
            std.debug.warn("LET {} =\n", .{local.name});
            printExpression(first_pass_result, module, locals, x.expression, indentation + 1);
        },
        .output => |expression| {
            std.debug.warn("OUT\n", .{});
            printExpression(first_pass_result, module, locals, expression, indentation + 1);
        },
    }
}

fn printExpression(first_pass_result: FirstPassResult, module: Module, locals: []const Local, expression: *const Expression, indentation: usize) void {
    const fields = first_pass_result.module_fields[module.first_field .. module.first_field + module.num_fields];

    var i: usize = 0;
    while (i < indentation) : (i += 1) {
        std.debug.warn("    ", .{});
    }
    switch (expression.inner) {
        .call => |call| {
            const field = fields[call.field_index];
            const callee_module = first_pass_result.modules[field.resolved_module_index];
            std.debug.warn("call self.{} (\n", .{field.name});
            for (call.args.span()) |arg| {
                i = 0;
                while (i < indentation + 1) : (i += 1) {
                    std.debug.warn("    ", .{});
                }
                std.debug.warn("{}:\n", .{
                    first_pass_result.module_params[callee_module.first_param + arg.callee_param_index].name,
                });
                printExpression(first_pass_result, module, locals, arg.value, indentation + 2);
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
                printStatement(first_pass_result, module, locals, statement, indentation + 1);
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
        .literal => |literal| {
            switch (literal) {
                .boolean => |v| std.debug.warn("{}\n", .{v}),
                .number => |v| std.debug.warn("{d}\n", .{v}),
                .enum_value => |str| std.debug.warn("'{}'\n", .{str}),
            }
        },
        .self_param => |param_index| {
            std.debug.warn("${}\n", .{param_index});
        },
        .bin_arith => |m| {
            switch (m.op) {
                .add => std.debug.warn("add\n", .{}),
                .mul => std.debug.warn("mul\n", .{}),
            }
            printExpression(first_pass_result, module, locals, m.a, indentation + 1);
            printExpression(first_pass_result, module, locals, m.b, indentation + 1);
        },
    }
}
