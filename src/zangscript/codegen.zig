const std = @import("std");
const ModuleDef = @import("first_pass.zig").ModuleDef;
const Expression = @import("second_pass.zig").Expression;
const CallArg = @import("second_pass.zig").CallArg;
const Call = @import("second_pass.zig").Call;

pub const InstrCallArg = union(enum) {
    // what goes here? -
    // a value. either a temp or a literal
    temp: usize,
    literal: f32,
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

            const callee_temps: usize = 0; // FIXME
            var i: usize = 0;
            while (i < callee_temps) : (i += 1) {
                try icall.temps.append(num_temps);
                num_temps += 1;
            }

            // we need to look at the field being called. get its module "signature" (num outputs, num temps).
            // we don't actually know that stuff yet.
            // (it will be a little complicated to get - will have to do codegen lazily)
            const field = &module_def.fields.span()[call.field_index];
            switch (field.resolved_type) {
                .builtin_module => |mod_ptr| {
                    // we know that zang.PulseOsc has 1 output and 0 temps.
                    // so WE need a temp in order to store the output.
                    // also need a step to fill out the inner params. these might be calls in themselves ...
                    // if they are, then they need temps generated for them.
                    // bytecode for a call should be:
                    // each param is either a temp or a literal value.
                    try icall.args.append(.{
                        .temp = num_temps,
                    });
                    num_temps += 1;
                },
                .script_module => |module_index| {
                    try icall.args.append(.{
                        .temp = num_temps,
                    });
                    num_temps += 1;
                    //unreachable; // TODO
                },
            }

            try instructions.append(.{ .call = icall });
        },
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
