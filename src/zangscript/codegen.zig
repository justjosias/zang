const std = @import("std");
const ModuleDef = @import("first_pass.zig").ModuleDef;
const Expression = @import("second_pass.zig").Expression;
const CallArg = @import("second_pass.zig").CallArg;
const Call = @import("second_pass.zig").Call;
const Literal = @import("second_pass.zig").Literal;

pub const InstrCallArg = union(enum) {
    temp: usize,
    literal: Literal,
    //self_param: usize,
};

pub const InstrCall = struct {
    result_loc: ResultLoc,
    field_index: usize,
    // list of temp indices
    temps: std.ArrayList(usize),
    // in the order of the callee module's params
    args: std.ArrayList(InstrCallArg),
};

pub const ResultLoc = union(enum) {
    temp: usize,
    output: usize,
};

pub const Instruction = union(enum) {
    call: InstrCall,
};

pub fn codegen(module_def: *ModuleDef, expression: *const Expression, allocator: *std.mem.Allocator) !void {
    var instructions = std.ArrayList(Instruction).init(allocator);
    // TODO deinit

    // visit this expression node.
    var num_temps: usize = 0;
    switch (expression.*) {
        .call => |call| {
            var icall: InstrCall = .{
                .result_loc = .{ .output = 0 },
                .field_index = call.field_index,
                .temps = std.ArrayList(usize).init(allocator),
                .args = std.ArrayList(InstrCallArg).init(allocator),
            };
            // TODO deinit

            const callee = module_def.fields.span()[call.field_index].resolved_module;

            // the callee needs temps for its own internal use
            var i: usize = 0;
            while (i < callee.num_temps) : (i += 1) {
                try icall.temps.append(num_temps);
                num_temps += 1;
            }

            //pub const CallArg = struct {
            //    arg_name: []const u8,
            //    value: *const Expression,
            //};
            //pub const ModuleParam = struct {
            //    name: []const u8,
            //    param_type: ResolvedParamType,
            //};

            // pass params
            for (callee.params) |_, j| {
                const arg = &call.args.span()[j];
                switch (arg.value.*) {
                    .literal => |literal| {
                        try icall.args.append(.{ .literal = literal });
                    },
                    .call => unreachable, // not implemented
                    .nothing => unreachable, // this should be impossible?
                }
                // just allocating a temp to use for the param value
                // TODO do something meaningful instead
                // add the ability to use one of our own param values
                //try icall.args.append(.{
                //    .temp = num_temps,
                //});
                //num_temps += 1;
            }

            try instructions.append(.{ .call = icall });
        },
        .literal => {},
        .nothing => {},
    }

    module_def.resolved.num_outputs = 1;
    module_def.resolved.num_temps = num_temps;
    module_def.instructions = instructions.span();

    std.debug.warn("num_temps: {}\n", .{num_temps});
    printBytecode(module_def, instructions.span());
    std.debug.warn("\n", .{});
}

pub fn printBytecode(module_def: *const ModuleDef, instructions: []const Instruction) void {
    std.debug.warn("bytecode:\n", .{});
    for (instructions) |instr| {
        std.debug.warn("    ", .{});
        switch (instr) {
            .call => |call| {
                switch (call.result_loc) {
                    .temp => |n| std.debug.warn("temp{}", .{n}),
                    .output => |n| std.debug.warn("output{}", .{n}),
                }
                std.debug.warn(" = CALL #{}({})", .{ call.field_index, module_def.fields.span()[call.field_index].name });
                for (call.args.span()) |arg| {
                    switch (arg) {
                        .temp => |v| {
                            std.debug.warn(" temp{}", .{v});
                        },
                        .literal => |v| {
                            std.debug.warn(" {d}", .{v});
                        },
                    }
                }
            },
        }
        std.debug.warn("\n", .{});
    }
}
