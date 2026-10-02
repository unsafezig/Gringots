"""Append classes.dex (deflated) and native libs (stored) to base.apk.

.so files must be STORED (uncompressed) so the loader can mmap them;
zipalign -p then page-aligns them. Called by build-apk.ps1.
"""

import sys
import zipfile
from pathlib import Path

base, dexdir, libdir, out = sys.argv[1:5]
# Optional 5th arg: lib subdir inside the APK (default arm64-v8a).
# The release pipeline (build-apk.ps1) relies on the default; the
# emulator-only x86_64 test APK passes "x86_64".
lib_subdir = sys.argv[5] if len(sys.argv) > 5 else "arm64-v8a"

with zipfile.ZipFile(base) as zin:
    items = [(info, zin.read(info.filename)) for info in zin.infolist()]

with zipfile.ZipFile(out, "w") as zout:
    for info, data in items:
        zout.writestr(info, data)
    dex = Path(dexdir) / "classes.dex"
    zout.write(dex, "classes.dex", compress_type=zipfile.ZIP_DEFLATED)
    for so in sorted(Path(libdir).glob("*.so")):
        zout.write(so, f"lib/{lib_subdir}/{so.name}", compress_type=zipfile.ZIP_STORED)

print(f"packaged {out}")
