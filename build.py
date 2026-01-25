import contextlib
import shutil
import typing
from pathlib import Path

import pydust
from pydust.build import build


@contextlib.contextmanager
def ensure_ffi_location() -> typing.Iterator[None]:
    """For some reason, `zig translate-c` is looking for `ffi.h` in the wrong location."""
    dst = Path("pydust/src/ffi.h")
    dst.parent.mkdir(parents=True, exist_ok=True)
    src = Path(pydust.__file__).parent / "src" / "ffi.h"
    shutil.copyfile(src, dst)
    yield
    shutil.rmtree(Path("pydust"))


with ensure_ffi_location():
    build()
