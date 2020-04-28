const tokenize = @import("zangscript/tokenize.zig");
pub const Source = tokenize.Source;

const builtins = @import("zangscript/builtins.zig");
pub const BuiltinEnum = builtins.BuiltinEnum;
pub const BuiltinModule = builtins.BuiltinModule;
pub const BuiltinPackage = builtins.BuiltinPackage;
pub const getBuiltinModule = builtins.getBuiltinModule;
pub const zang_builtin_package = builtins.zang_builtin_package;

const parse_ = @import("zangscript/parse.zig");
pub const ModuleParam = parse_.ModuleParam;
pub const parse = parse_.parse;

const codegen_ = @import("zangscript/codegen.zig");
pub const codegen = codegen_.codegen;

const codegen_zig = @import("zangscript/codegen_zig.zig");
pub const generateZig = codegen_zig.generateZig;
