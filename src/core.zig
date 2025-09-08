const py = @import("pydust");

const root = @This();

pub fn mask() !py.PyString(root) {
    return try py.PyString(root).create("Hello, Sweeper!");
}

comptime {
    py.rootmodule(root);
}
