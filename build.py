import shutil
from pathlib import Path

from pydust.build import build

import pydust

dst = Path("pydust/src/ffi.h")
dst.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(
    Path(pydust.__file__).parent / "src" / "ffi.h",
    dst
)

build()
