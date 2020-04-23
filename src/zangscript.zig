const zangscript = @import("zangscript/zangscript.zig");
pub const Script = zangscript.Script;
pub const loadScript = zangscript.loadScript;

const builtins = @import("zangscript/builtins.zig");
pub const BuiltinModule = builtins.BuiltinModule;
pub const BuiltinPackage = builtins.BuiltinPackage;
pub const getBuiltinModule = builtins.getBuiltinModule;
pub const zang_builtin_package = builtins.zang_builtin_package;

const parse = @import("zangscript/parse.zig");
pub const ModuleParam = parse1.ModuleParam;

const codegen_zig = @import("zangscript/codegen_zig.zig");
pub const generateZig = codegen_zig.generateZig;
