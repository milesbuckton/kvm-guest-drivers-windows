#!/usr/bin/env python3
"""Run an MSVC link.exe/lib.exe command, retargeting it from ARM64 to ARM64EC.

Meson has no ARM64EC support: with an ARM64 cl.exe it always passes
/MACHINE:ARM64 to link.exe and lib.exe, on the command line or inside an
@response file. This wrapper rewrites that one switch to /MACHINE:ARM64EC and
runs the real tool. Use it from a meson cross file:

    c_ld = ['python', 'msvc_arm64ec_wrap.py', 'link']
    ar   = ['python', 'msvc_arm64ec_wrap.py', 'lib']

Anything else (including /MACHINE:ARM64EC and /MACHINE:ARM64X) is passed
through unchanged, so the tool's own output (which meson parses to detect
link.exe and lib.exe) is preserved.
"""

import os
import re
import subprocess
import sys
import tempfile

_ARG_RE = re.compile(r'^([/-]machine:)arm64$', re.IGNORECASE)
_TEXT_RE = re.compile(r'([/-]machine:)arm64(?![A-Za-z0-9_])', re.IGNORECASE)
_BYTES_RE = re.compile(rb'([/-]machine:)arm64(?![A-Za-z0-9_])', re.IGNORECASE)


def _rewrite_rsp(path):
    """Return the path of an ARM64EC copy of a response file, or None."""
    try:
        with open(path, 'rb') as f:
            data = f.read()
    except OSError:
        return None

    if data.startswith(b'\xff\xfe') or data.startswith(b'\xfe\xff'):
        # UTF-16 response file (BOM required by the MSVC tools).
        text = data.decode('utf-16')
        new_text, count = _TEXT_RE.subn(r'\1ARM64EC', text)
        new_data = new_text.encode('utf-16') if count else None
    else:
        # ANSI/UTF-8: work on bytes so other content is left untouched.
        new_data, count = _BYTES_RE.subn(rb'\1ARM64EC', data)
        if not count:
            new_data = None

    if new_data is None:
        return None

    fd, new_path = tempfile.mkstemp(suffix='.rsp', prefix='arm64ec_',
                                    dir=os.path.dirname(os.path.abspath(path)))
    with os.fdopen(fd, 'wb') as f:
        f.write(new_data)
    return new_path


def main(argv):
    if len(argv) < 2:
        sys.stderr.write('usage: msvc_arm64ec_wrap.py <link|lib> [args...]\n')
        return 2

    tool = argv[1]
    args = []
    temp_files = []
    for arg in argv[2:]:
        if _ARG_RE.match(arg):
            args.append(_ARG_RE.sub(r'\1ARM64EC', arg))
        elif arg.startswith('@'):
            new_rsp = _rewrite_rsp(arg[1:])
            if new_rsp:
                temp_files.append(new_rsp)
                args.append('@' + new_rsp)
            else:
                args.append(arg)
        else:
            args.append(arg)

    try:
        return subprocess.call([tool] + args)
    finally:
        for path in temp_files:
            try:
                os.remove(path)
            except OSError:
                pass


if __name__ == '__main__':
    sys.exit(main(sys.argv))
