"""Remove the Music bookmark while preserving other KDE Places and metadata."""

import os
from pathlib import Path
import stat
import sys
import tempfile
from urllib.parse import unquote, urlsplit
from xml.dom import minidom

target = Path(sys.argv[1])
music = Path(sys.argv[2])
if not music.is_absolute():
    sys.exit(0)
music = music.resolve()
# XDG uses the home directory when a special folder is disabled.
if not target.exists() or music == Path.home().resolve():
    sys.exit(0)

document = minidom.parse(str(target))
removed = False
for bookmark in list(document.getElementsByTagName("bookmark")):
    url = urlsplit(bookmark.getAttribute("href"))
    if url.scheme != "file" or url.netloc not in ("", "localhost"):
        continue
    if Path(unquote(url.path)).resolve() == music:
        bookmark.parentNode.removeChild(bookmark)
        bookmark.unlink()
        removed = True

if removed:
    # Keep the file writable and replace it atomically, never touching folders.
    mode = stat.S_IMODE(target.stat().st_mode)
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as output:
        output.write(document.toxml(encoding="UTF-8"))
        temporary = Path(output.name)
    try:
        temporary.chmod(mode)
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)

document.unlink()
