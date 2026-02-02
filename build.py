import contextlib
import shutil
import sys
import sysconfig
import typing
from pathlib import Path

import pydust
from pydust.build import build


def _ensure_ld_library() -> None:
    """
    Pydust assumes LDLIBRARY is always set, but on Windows (especially in PEP 517 isolated builds) it may be None.
    Provide a correct fallback.
    """
    if sys.platform != "win32":
        return

    if sysconfig.get_config_var("LDLIBRARY") is None:
        sysconfig._CONFIG_VARS["LDLIBRARY"] = f"python{sys.version_info.major}{sys.version_info.minor}.lib"


@contextlib.contextmanager
def ensure_ffi_location() -> typing.Iterator[None]:
    """
    For some reason, `zig translate-c` is looking for `ffi.h` in the wrong location.
    """
    dst = Path("pydust/src/ffi.h")
    dst.parent.mkdir(parents=True, exist_ok=True)
    src = Path(pydust.__file__).parent / "src" / "ffi.h"
    shutil.copyfile(src, dst)
    yield
    shutil.rmtree(Path("pydust"))


_ensure_ld_library()

with ensure_ffi_location():
    build()
