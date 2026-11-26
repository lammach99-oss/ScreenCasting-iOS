"""Validate the built plist or its copy inside the exported IPA."""
import plistlib
import re
import sys
import zipfile
from pathlib import Path


def validated_family(path):
    if path.suffix == ".ipa":
        with zipfile.ZipFile(path) as archive:
            entries = [name for name in archive.namelist()
                       if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
            if len(entries) != 1:
                raise SystemExit("Expected one app Info.plist")
            info = plistlib.loads(archive.read(entries[0]))
    else:
        info = plistlib.loads(path.read_bytes())
    values = info.get("UIDeviceFamily")
    if (not isinstance(values, list) or not all(type(v) is int for v in values)
            or sorted(values) != [1, 2]):
        raise SystemExit("Expected UIDeviceFamily containing exactly iPhone and iPad")
    return ",".join(str(v) for v in sorted(values))


if __name__ == "__main__":
    print(validated_family(Path(sys.argv[1])))
