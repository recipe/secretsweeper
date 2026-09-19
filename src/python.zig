//! CPython extension module `secretsweeper._native`.
//!
//! The complete binding over the Aho-Corasick automaton: construction,
//! masking (one-shot and streaming), the streaming reminder and destruction.
//! `secretsweeper._core` calls it directly; wheels that ship this module carry
//! no other binary. Where it cannot be built (free-threaded CPython before
//! 3.15, which has no stable ABI; non-CPython interpreters; Windows builds
//! without the stable ABI import library) `secretsweeper._ctypes_backend`
//! drives the C-ABI shared library from `export.zig` instead and exposes the
//! same five functions.
//!
//! Receiving the Python argument objects directly (METH_FASTCALL) and building
//! the result bytes in native code keeps the per-call overhead at the level of
//! a builtin function: the streaming `mask` runs once per console line, where
//! generic ctypes marshaling used to dominate (~700ns per call against ~40ns
//! of automaton work).
//!
//! Uses the CPython stable ABI (METH_FASTCALL joined the limited API in 3.10,
//! the buffer protocol in 3.11; the package requires >=3.11). The needed C API
//! functions and struct layouts are declared manually, so no Python headers
//! are required at build time; the symbols resolve against the hosting
//! interpreter when the module is imported. Python 3.15+ free-threaded builds
//! use abi3t and the layout-independent export hook in python_abi3t.zig. The
//! automaton travels as a PyCapsule, which has no layout dependence either, so
//! every function here works unchanged under both ABIs.

const std = @import("std");
const Aho = @import("aho.zig").Aho;

const allocator = std.heap.c_allocator;

const PyObject = opaque {};
const PyThreadState = opaque {};

// Stable-ABI declarations (manual, no Python.h)

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

/// `Py_buffer`, part of the limited API since Python 3.11.
const Py_buffer = extern struct {
    buf: ?[*]u8,
    obj: ?*PyObject,
    len: isize,
    itemsize: isize,
    readonly: c_int,
    ndim: c_int,
    format: ?[*:0]u8,
    shape: ?*isize,
    strides: ?*isize,
    suboffsets: ?*isize,
    internal: ?*anyopaque,
};

const PyBUF_SIMPLE: c_int = 0;
const METH_FASTCALL: c_int = 0x0080;
/// `PYTHON_ABI_VERSION`: marks the module as stable-ABI for `PyModule_Create2`.
const PYTHON_ABI_VERSION: c_int = 3;

const PyCapsule_Destructor = *const fn (?*PyObject) callconv(.c) void;

extern fn PyModule_Create2(def: *PyModuleDef, api_version: c_int) ?*PyObject;
extern fn PyBytes_FromStringAndSize(v: ?[*]const u8, len: isize) ?*PyObject;
extern fn PyBytes_AsStringAndSize(obj: *PyObject, buffer: *?[*]u8, length: *isize) c_int;
extern fn PyLong_AsUnsignedLongLong(obj: *PyObject) c_ulonglong;
extern fn PyObject_IsTrue(obj: *PyObject) c_int;
extern fn PyObject_GetIter(obj: *PyObject) ?*PyObject;
extern fn PyIter_Next(iter: *PyObject) ?*PyObject;
extern fn PyObject_Type(obj: *PyObject) ?*PyObject;
extern fn PyObject_GetBuffer(obj: *PyObject, view: *Py_buffer, flags: c_int) c_int;
extern fn PyBuffer_Release(view: *Py_buffer) void;
extern fn PyCapsule_New(pointer: *anyopaque, name: ?[*:0]const u8, destructor: ?PyCapsule_Destructor) ?*PyObject;
extern fn PyCapsule_GetPointer(capsule: *PyObject, name: ?[*:0]const u8) ?*anyopaque;
extern fn PyCapsule_SetDestructor(capsule: *PyObject, destructor: ?PyCapsule_Destructor) c_int;
extern fn PyCapsule_SetName(capsule: *PyObject, name: ?[*:0]const u8) c_int;
extern fn PyEval_SaveThread() ?*PyThreadState;
extern fn PyEval_RestoreThread(tstate: ?*PyThreadState) void;
extern fn Py_IncRef(obj: ?*PyObject) void;
extern fn Py_DecRef(obj: ?*PyObject) void;
extern fn PyErr_Occurred() ?*PyObject;
extern fn PyErr_SetString(exc: *PyObject, msg: [*:0]const u8) void;
extern fn PyErr_Format(exc: *PyObject, format: [*:0]const u8, ...) ?*PyObject;
extern fn PyErr_ExceptionMatches(exc: *PyObject) c_int;
extern fn PyErr_Clear() void;
extern var PyExc_TypeError: *PyObject;
extern var PyExc_MemoryError: *PyObject;

/// `Py_None` is `&_Py_NoneStruct`; the struct itself is opaque to us.
const Py_None = @extern(*PyObject, .{ .name = "_Py_NoneStruct" });

fn none() *PyObject {
    Py_IncRef(Py_None);
    return Py_None;
}

// Automaton handle

const CAPSULE_NAME: [*:0]const u8 = "secretsweeper.automaton";
/// `destroy` renames the capsule so that any later use fails loudly in
/// `PyCapsule_GetPointer` (ValueError) instead of touching freed memory.
const DESTROYED_CAPSULE_NAME: [*:0]const u8 = "secretsweeper.automaton (destroyed)";

fn destroyAutomaton(ac: *Aho) void {
    ac.deinit();
    allocator.destroy(ac);
}

fn capsuleDestructor(capsule: ?*PyObject) callconv(.c) void {
    // Only ever installed on live capsules with the live name, so this cannot fail.
    const ptr = PyCapsule_GetPointer(capsule.?, CAPSULE_NAME) orelse return;
    destroyAutomaton(@ptrCast(@alignCast(ptr)));
}

/// The automaton behind a capsule argument; sets a Python exception and
/// returns null for anything else, including a destroyed automaton.
fn automatonArg(obj: *PyObject) ?*Aho {
    const ptr = PyCapsule_GetPointer(obj, CAPSULE_NAME) orelse return null;
    return @ptrCast(@alignCast(ptr));
}

// Module functions

/// A Python exception has been set; the caller returns null.
const PyError = error{PythonError};

fn memoryError(msg: [*:0]const u8) PyError {
    PyErr_SetString(PyExc_MemoryError, msg);
    return error.PythonError;
}

/// Creates an automaton, inserts every pattern from the iterable and builds
/// it. With `use_dfa` the DFA is built unless the pattern set exceeds
/// `Aho.DFA_MEMORY_CAP`, in which case the classic goto/fail-link
/// representation is used; without it the classic build is forced (see
/// `_core._FORCE_NO_DFA_AUTOMATON_ENV`).
fn buildAutomaton(patterns: *PyObject, use_dfa: bool) PyError!*Aho {
    const ac = allocator.create(Aho) catch return memoryError("failed to create the automaton");
    errdefer allocator.destroy(ac);
    ac.* = Aho.init(allocator) catch return memoryError("failed to create the automaton");
    errdefer ac.deinit();

    const iter = PyObject_GetIter(patterns) orelse return error.PythonError;
    defer Py_DecRef(iter);
    while (PyIter_Next(iter)) |item| {
        defer Py_DecRef(item);
        var buf: ?[*]u8 = null;
        var len: isize = 0;
        if (PyBytes_AsStringAndSize(item, &buf, &len) != 0) {
            if (PyErr_ExceptionMatches(PyExc_TypeError) != 0) {
                // Same wording as the ctypes backend's own check.
                PyErr_Clear();
                if (PyObject_Type(item)) |item_type| {
                    defer Py_DecRef(item_type);
                    _ = PyErr_Format(PyExc_TypeError, "expected bytes, found %R", item_type);
                }
            }
            return error.PythonError;
        }
        _ = ac.insert(if (len > 0) buf.?[0..@intCast(len)] else "") catch
            return memoryError("failed to insert a pattern");
    }
    // PyIter_Next returns null both at exhaustion and on error.
    if (PyErr_Occurred() != null) return error.PythonError;

    const dfa_built = if (use_dfa)
        ac.buildDfa() catch return memoryError("failed to build the automaton")
    else
        false;
    if (!dfa_built) {
        ac.build() catch return memoryError("failed to build the automaton");
    }
    return ac;
}

/// `new(patterns: Iterable[bytes], use_dfa: bool) -> automaton`
fn new(self: ?*PyObject, args: ?[*]const ?*PyObject, nargs: isize) callconv(.c) ?*PyObject {
    _ = self;
    if (nargs != 2) {
        PyErr_SetString(PyExc_TypeError, "new expects (patterns, use_dfa)");
        return null;
    }
    const argv = args.?;
    const use_dfa = PyObject_IsTrue(argv[1].?);
    if (use_dfa < 0) return null;
    const ac = buildAutomaton(argv[0].?, use_dfa != 0) catch return null;
    return PyCapsule_New(ac, CAPSULE_NAME, &capsuleDestructor) orelse {
        destroyAutomaton(ac);
        return null;
    };
}

/// Inputs at least this long release the GIL for the duration of a one-shot
/// mask, matching what ctypes did on every call. Streaming chunks never do:
/// they are small, and the switch cost outweighed the automaton work by far
/// when measured (8.6x lower multi-threaded throughput).
const GIL_RELEASE_THRESHOLD: usize = 64 * 1024;

/// `mask(automaton, data: Buffer, limit: int, is_streaming: bool) -> bytes`
///
/// `data` is any C-contiguous buffer (bytes, bytearray, memoryview). In
/// streaming mode the caller must hold the owning _StreamWrapper's lock for
/// the entire call; direct concurrent calls with the same automaton are
/// unsupported.
fn mask(self: ?*PyObject, args: ?[*]const ?*PyObject, nargs: isize) callconv(.c) ?*PyObject {
    _ = self;
    if (nargs != 4) {
        PyErr_SetString(PyExc_TypeError, "mask expects (automaton, data, limit, is_streaming)");
        return null;
    }
    const argv = args.?;
    const ac = automatonArg(argv[0].?) orelse return null;
    const limit = PyLong_AsUnsignedLongLong(argv[2].?);
    if (limit == std.math.maxInt(c_ulonglong) and PyErr_Occurred() != null) return null;
    const is_streaming = PyObject_IsTrue(argv[3].?);
    if (is_streaming < 0) return null;

    var view: Py_buffer = undefined;
    if (PyObject_GetBuffer(argv[1].?, &view, PyBUF_SIMPLE) != 0) return null;
    defer PyBuffer_Release(&view);
    const text: []const u8 = if (view.len > 0) view.buf.?[0..@intCast(view.len)] else "";

    // The exported buffer pins `data` for as long as `view` lives, so the
    // automaton may read it without the GIL; nothing else Python-side is touched.
    const release_gil = is_streaming == 0 and text.len >= GIL_RELEASE_THRESHOLD;
    const tstate = if (release_gil) PyEval_SaveThread() else null;
    const result = ac.mask(.{
        .text = text,
        .max_stars = limit,
        .is_streaming = is_streaming != 0,
    });
    if (release_gil) PyEval_RestoreThread(tstate);

    const masked = result catch {
        PyErr_SetString(PyExc_MemoryError, "failed to mask the input");
        return null;
    };
    defer ac.allocator.free(masked);
    return PyBytes_FromStringAndSize(if (masked.len > 0) masked.ptr else null, @intCast(masked.len));
}

/// `get_reminder(automaton) -> bytes`: the streaming-mode reminder, empty if none.
fn getReminder(self: ?*PyObject, args: ?[*]const ?*PyObject, nargs: isize) callconv(.c) ?*PyObject {
    _ = self;
    if (nargs != 1) {
        PyErr_SetString(PyExc_TypeError, "get_reminder expects (automaton)");
        return null;
    }
    const ac = automatonArg(args.?[0].?) orelse return null;
    const reminder: []const u8 = ac.reminder orelse "";
    return PyBytes_FromStringAndSize(if (reminder.len > 0) reminder.ptr else null, @intCast(reminder.len));
}

/// `reset_reminder(automaton) -> None`: drops the streaming-mode reminder.
fn resetReminder(self: ?*PyObject, args: ?[*]const ?*PyObject, nargs: isize) callconv(.c) ?*PyObject {
    _ = self;
    if (nargs != 1) {
        PyErr_SetString(PyExc_TypeError, "reset_reminder expects (automaton)");
        return null;
    }
    const ac = automatonArg(args.?[0].?) orelse return null;
    ac.reset_reminder();
    return none();
}

/// `destroy(automaton) -> None`
///
/// Frees the automaton now rather than when the capsule is garbage collected.
/// The capsule stays valid as an object but every further call with it raises
/// ValueError, including a second `destroy`.
fn destroy(self: ?*PyObject, args: ?[*]const ?*PyObject, nargs: isize) callconv(.c) ?*PyObject {
    _ = self;
    if (nargs != 1) {
        PyErr_SetString(PyExc_TypeError, "destroy expects (automaton)");
        return null;
    }
    const capsule = args.?[0].?;
    const ac = automatonArg(capsule) orelse return null;
    // Disarm first: were the rename to fail, the destructor would still run
    // later and free twice, whereas leaving the pointer set is harmless.
    if (PyCapsule_SetDestructor(capsule, null) != 0) return null;
    if (PyCapsule_SetName(capsule, DESTROYED_CAPSULE_NAME) != 0) return null;
    destroyAutomaton(ac);
    return none();
}

var methods = [_]PyMethodDef{
    .{
        .ml_name = "new",
        .ml_meth = @ptrCast(&new),
        .ml_flags = METH_FASTCALL,
        .ml_doc = "new(patterns, use_dfa) -> automaton",
    },
    .{
        .ml_name = "mask",
        .ml_meth = @ptrCast(&mask),
        .ml_flags = METH_FASTCALL,
        .ml_doc = "mask(automaton, data, limit, is_streaming) -> bytes",
    },
    .{
        .ml_name = "get_reminder",
        .ml_meth = @ptrCast(&getReminder),
        .ml_flags = METH_FASTCALL,
        .ml_doc = "get_reminder(automaton) -> bytes",
    },
    .{
        .ml_name = "reset_reminder",
        .ml_meth = @ptrCast(&resetReminder),
        .ml_flags = METH_FASTCALL,
        .ml_doc = "reset_reminder(automaton) -> None",
    },
    .{
        .ml_name = "destroy",
        .ml_meth = @ptrCast(&destroy),
        .ml_flags = METH_FASTCALL,
        .ml_doc = "destroy(automaton) -> None",
    },
    .{}, // sentinel
};

var module_def = PyModuleDef{
    .m_base = .{ .ob_base = .{ .ob_refcnt = 1, .ob_type = null } },
    .m_name = "secretsweeper._native",
    .m_methods = &methods,
};

fn initLegacy() callconv(.c) ?*PyObject {
    return PyModule_Create2(&module_def, PYTHON_ABI_VERSION);
}

const abi3t = @import("python_abi3t.zig");
const module_slots = abi3t.moduleSlots(&methods);

fn exportModule() callconv(.c) [*]const abi3t.PySlot {
    return &module_slots;
}

comptime {
    // Export only the selected initialization hook: abi3t must never instantiate
    // the legacy PyModuleDef, whose embedded PyObject header assumes the GIL ABI.
    if (@import("python_options").abi3t) {
        @export(&exportModule, .{ .name = "PyModExport__native" });
    } else {
        @export(&initLegacy, .{ .name = "PyInit__native" });
    }
}
