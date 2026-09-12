//! Python 3.15 stable ABI declarations (PEPs 793, 803 and 820).
//! Layouts/constants mirror Include/slots.h, slots_generated.h and modsupport.h.
//! These contain no PyObject headers and work with both interpreter GIL modes.
//! https://docs.python.org/3.15/howto/abi3t-migration.html

pub const PySlot = extern struct {
    id: u16 = 0,
    flags: u16 = 0,
    reserved: u32 = 0,
    value: extern union {
        ptr: ?*const anyopaque,
        func: ?*const fn () callconv(.c) void,
        size: isize,
        int64: i64,
        uint64: u64,
    } = .{ .uint64 = 0 },
};

const PyABIInfo = extern struct {
    major_version: u8 = 1,
    minor_version: u8 = 0,
    // PyABIInfo_STABLE | PyABIInfo_FREETHREADING_AGNOSTIC
    flags: u16 = 0x0001 | 0x0002 | 0x0004,
    // We use handwritten declarations targeting the 3.15 ABI, not host headers.
    build_version: u32 = 0x030f0000,
    abi_version: u32 = 0x030f0000,
};

const abi_info = PyABIInfo{};
const PySlot_STATIC = 0x0002;
const PySlot_INTPTR = 0x0004;
const Py_mod_gil = 87;
const Py_mod_name = 100;
const Py_mod_methods = 103;
const Py_mod_abi = 109;

pub fn moduleSlots(methods: *const anyopaque) [5]PySlot {
    return .{
        .{ .id = Py_mod_abi, .flags = PySlot_STATIC, .value = .{ .ptr = &abi_info } },
        .{ .id = Py_mod_name, .flags = PySlot_STATIC, .value = .{ .ptr = "secretsweeper._native" } },
        .{ .id = Py_mod_methods, .flags = PySlot_STATIC, .value = .{ .ptr = methods } },
        // Py_MOD_GIL_NOT_USED is the pointer-valued constant (void *)1.
        .{ .id = Py_mod_gil, .flags = PySlot_INTPTR, .value = .{ .ptr = @ptrFromInt(1) } },
        .{},
    };
}
