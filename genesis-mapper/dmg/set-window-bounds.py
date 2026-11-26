"""Reads or sets the installer window's saved bounds in a volume's .DS_Store.

Finder saves the window's bounds when the build script lays the window out,
but a window manager on the build Mac can resize the window afterwards and
Finder saves that too. The build reads the bounds Finder first saved and
writes them back once Finder has let go of the disk.

Usage: python3 -I set-window-bounds.py <.DS_Store> get
       python3 -I set-window-bounds.py <.DS_Store> set "{{x, y}, {w, h}}"
It only swaps the stored string for one of the same length, padding with
spaces (which Finder ignores), so the file's structure is untouched.
"""
import plistlib
import sys

MARKER = b"bwspblob"


def record(data):
    at = data.find(MARKER)
    if at < 0 or data.find(MARKER, at + 1) >= 0:
        sys.exit("expected exactly one window record in .DS_Store")
    start = at + len(MARKER) + 4
    length = int.from_bytes(data[at + len(MARKER):start], "big")
    bounds = plistlib.loads(bytes(data[start:start + length])).get("WindowBounds")
    if not isinstance(bounds, str):
        sys.exit("window record has no bounds")
    return start, length, bounds


path, mode = sys.argv[1], sys.argv[2]
data = bytearray(open(path, "rb").read())
start, length, old = record(data)
if mode == "get":
    print(old)
    sys.exit()
new = " ".join(sys.argv[3].split())
if len(new) > len(old):
    sys.exit("new bounds are longer than the stored ones: %r vs %r" % (new, old))
cut = new.rfind(", ") + 2
new = new[:cut] + " " * (len(old) - len(new)) + new[cut:]
# A binary plist stores an ASCII string as its plain bytes, so a value of the
# same length can be swapped in place.
blob = bytes(data[start:start + length])
if blob.count(old.encode("ascii")) != 1:
    sys.exit("could not find the stored bounds exactly once")
blob = blob.replace(old.encode("ascii"), new.encode("ascii"))
if plistlib.loads(blob).get("WindowBounds") != new:
    sys.exit("rewritten record did not read back; not writing")
data[start:start + length] = blob
open(path, "wb").write(data)
print("window bounds:", repr(old), "->", repr(new))
