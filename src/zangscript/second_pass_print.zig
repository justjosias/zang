const std = @import("std");
const FirstPassResult = @import("first_pass.zig").FirstPassResult;
const Module = @import("first_pass.zig").Module;
const ModuleField = @import("first_pass.zig").ModuleField;
const Expression = @import("second_pass.zig").Expression;

pub fn secondPassPrintModule(first_pass_result: FirstPassResult, module: Module, expression: *const Expression, indentation: usize) void {
    const fields = first_pass_result.module_fields[module.first_field .. module.first_field + module.num_fields];

    std.debug.warn("module '{}'\n", .{module.name});
    for (fields) |field| {
        std.debug.warn("    field {}: {}\n", .{ field.name, field.type_name });
    }
    std.debug.warn("expression:\n", .{});
    printExpression(fields, expression, 1);
    std.debug.warn("\n", .{});
}

fn printExpression(fields: []const ModuleField, expression: *const Expression, indentation: usize) void {
    var i: usize = 0;
    while (i < indentation) : (i += 1) {
        std.debug.warn("    ", .{});
    }
    switch (expression.inner) {
        .call => |call| {
            std.debug.warn("call self.{} (\n", .{fields[call.field_index].name});
            for (call.args.span()) |arg| {
                i = 0;
                while (i < indentation + 1) : (i += 1) {
                    std.debug.warn("    ", .{});
                }
                std.debug.warn("{}:\n", .{arg.arg_name});
                printExpression(fields, arg.value, indentation + 2);
            }
            i = 0;
            while (i < indentation) : (i += 1) {
                std.debug.warn("    ", .{});
            }
            std.debug.warn(")\n", .{});
        },
        .literal => |literal| {
            switch (literal) {
                .boolean => |v| std.debug.warn("{}\n", .{v}),
                .number => |v| std.debug.warn("{d}\n", .{v}),
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
            printExpression(fields, m.a, indentation + 1);
            printExpression(fields, m.b, indentation + 1);
        },
    }
}
