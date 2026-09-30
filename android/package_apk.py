"""Append classes.dex (deflated) and native libs (stored) to base.apk.

.so files must be STORED (uncompressed) so the loader can mmap them;
zipalign -p then page-aligns them. Called by build-apk.ps1.
"""

import sys
import zipfile
from pathlib import Path

base, dexdir, libdir, out = sys.argv[1:5]

with zipfile.ZipFile(base) as zin:
    items = [(info, zin.read(info.filename)) for info in zin.infolist()]

with zipfile.ZipFile(out, "w") as zout:
    for info, data in items:
        zout.writestr(info, data)
    dex = Path(dexdir) / "classes.dex"
    zout.write(dex, "classes.dex", compress_type=zipfile.ZIP_DEFLATED)
    for so in sorted(Path(libdir).glob("*.so")):
        zout.write(so, f"lib/arm64-v8a/{so.name}", compress_type=zipfile.ZIP_STORED)

print(f"packaged {out}")
