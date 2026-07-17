//! CPython extension module `secretsweeper._native`.
//!
//! Hot-path binding only: `masking_read` runs once per console line, and the
//! generic ctypes marshaling dominates its cost (~700ns per call, measured
//! against ~40ns of automaton work). This module receives the Python argument
//! objects directly (METH_FASTCALL) and builds the result bytes in native
//! code, cutting the per-call overhead to the level of a builtin function.
//! Cold-path calls (automaton construction, reminders, destruction) stay on
//! ctypes in `secretsweeper._core`, which also keeps a full ctypes fallback
//! for platforms where this extension is not built.
//!
//! Uses the CPython stable ABI (available since Python 3.2, METH_FASTCALL in
//! the limited API since 3.10; the package requires >=3.11). The needed C API
//! functions and struct layouts are declared manually, so no Python headers
//! are required at build time; the symbols resolve against the hosting
//! interpreter when the module is imported.
//!
//! The automaton handle is the pointer returned by `ss_new` in the ctypes
//! shared library. Both artifacts are compiled from the same sources in one
//! `zig build`, so the `Aho` layout is identical and the handle can be shared
//! across them; allocations flow through the `std.mem.Allocator` vtable
//! stored inside the automaton, so both sides use the same C allocator.

const std = @import("std");
const Aho = @import("aho.zig").Aho;

const PyObject = opaque {};

// --- Stable-ABI declarations (manual, no Python.h) ---

const PyObjectHeader = extern struct {
    ob_refcnt: isize,
    ob_type: ?*anyopaque,
};

const PyModuleDef_Base = extern struct {
    ob_base: PyObjectHeader,
    m_init: ?*const fn () callconv(.c) ?*PyObject = null,
    m_index: isize = 0,
    m_copy: ?*PyObject = null,
};

const PyMethodDef = extern struct {
    ml_name: ?[*:0]const u8 = null,
    ml_meth: ?*const anyopaque = null,
    ml_flags: c_int = 0,
    ml_doc: ?[*:0]const u8 = null,
};

const PyModuleDef = extern struct {
    m_base: PyModuleDef_Base,
    m_name: [*:0]const u8,
    m_doc: ?[*:0]const u8 = null,
    m_size: isize = -1,
    m_methods: ?[*]PyMethodDef = null,
    m_slots: ?*anyopaque = null,
    m_traverse: ?*const anyopaque = null,
    m_clear: ?*const anyopaque = null,
    m_free: ?*const anyopaque = null,
};

const METH_FASTCALL: c_int = 0x0080;
/// `PYTHON_ABI_VERSION`: marks the module as stable-ABI for `PyModule_Create2`.
const PYTHON_ABI_VERSION: c_int = 3;

extern fn PyModule_Create2(def: *PyModuleDef, api_version: c_int) ?*PyObject;
extern fn PyBytes_FromStringAndSize(v: ?[*]const u8, len: isize) ?*PyObject;
extern fn PyBytes_AsStringAndSize(obj: *PyObject, buffer: *?[*]u8, length: *isize) c_int;
extern fn PyLong_AsVoidPtr(obj: *PyObject) ?*anyopaque;
extern fn PyLong_AsUnsignedLongLong(obj: *PyObject) c_ulonglong;
extern fn PyErr_Occurred() ?*PyObject;
extern fn PyErr_SetString(exc: *PyObject, msg: [*:0]const u8) void;
extern var PyExc_TypeError: *PyObject;
extern var PyExc_MemoryError: *PyObject;

// --- Module functions ---

/// `masking_read(handle: int, data: bytes, limit: int) -> bytes`
///
/// Streaming mask over the chunk, mirroring `_StreamWrapper.masking_read`.
/// The GIL is held for the whole call, which serializes automaton mutation.
fn maskingRead(
    self: ?*PyObject,
    args: ?[*]const ?*PyObject,
    nargs: isize,
) callconv(.c) ?*PyObject {
    _ = self;
    if (nargs != 3) {
        PyErr_SetString(PyExc_TypeError, "masking_read expects (handle, data, limit)");
        return null;
    }
    const argv = args.?;
    const handle = PyLong_AsVoidPtr(argv[0].?) orelse {
        if (PyErr_Occurred() == null) {
            PyErr_SetString(PyExc_TypeError, "invalid automaton handle");
        }
        return null;
    };
    var buf: ?[*]u8 = null;
    var len: isize = 0;
    if (PyBytes_AsStringAndSize(argv[1].?, &buf, &len) != 0) {
        return null;
    }
    const limit = PyLong_AsUnsignedLongLong(argv[2].?);
    if (limit == std.math.maxInt(c_ulonglong) and PyErr_Occurred() != null) {
        return null;
    }

    const ac: *Aho = @ptrCast(@alignCast(handle));
    const masked = ac.mask(.{
        .text = if (len > 0) buf.?[0..@intCast(len)] else "",
        .max_stars = limit,
        .is_streaming = true,
    }) catch {
        PyErr_SetString(PyExc_MemoryError, "failed to mask the input");
        return null;
    };
    defer ac.allocator.free(masked);
    return PyBytes_FromStringAndSize(
        if (masked.len > 0) masked.ptr else null,
        @intCast(masked.len),
    );
}

var methods = [_]PyMethodDef{
    .{
        .ml_name = "masking_read",
        .ml_meth = @ptrCast(&maskingRead),
        .ml_flags = METH_FASTCALL,
        .ml_doc = "masking_read(handle, data, limit) -> bytes",
    },
    .{}, // sentinel
};

var module_def = PyModuleDef{
    .m_base = .{ .ob_base = .{ .ob_refcnt = 1, .ob_type = null } },
    .m_name = "secretsweeper._native",
    .m_methods = &methods,
};

export fn PyInit__native() ?*PyObject {
    return PyModule_Create2(&module_def, PYTHON_ABI_VERSION);
}
