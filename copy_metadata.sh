#!/usr/bin/env bash

# Author: Marco Marini
# Description: Copy native FLAC comments and pictures without decoding audio.
# License: MIT (see LICENSE)
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
command -v python3 >/dev/null 2>&1 || { printf 'python3 is required.\n' >&2; exit 1; }
exec python3 - "$@" <<'PY'
import argparse
import os
from pathlib import Path
import shutil
import struct
import sys
import tempfile

parser = argparse.ArgumentParser(prog='copy_metadata.sh', description=(
    'Replace FLAC tags and embedded pictures using another folder. '
    'Files match by relative path and name, ignoring the FLAC extension case '
    'and an optional .cdda suffix before it. Track numbers are never shifted. '
    'Audio is copied byte for byte; source files are unchanged. '
    'Unmatched destination files are left unchanged.'))
parser.add_argument('-s', '--source', required=True, type=Path)
parser.add_argument('-d', '--destination', required=True, type=Path)
parser.add_argument('-n', '--dry-run', action='store_true', help='validate and show matches without writing')
args = parser.parse_args()


def metadata(path):
    blocks = []
    with path.open('rb') as stream:
        if stream.read(4) != b'fLaC':
            raise ValueError(f'Not a native FLAC file: {path}')
        while True:
            header = stream.read(4)
            if len(header) != 4:
                raise ValueError(f'Truncated FLAC metadata: {path}')
            kind = header[0] & 127
            length = int.from_bytes(header[1:], 'big')
            data = stream.read(length)
            if len(data) != length or kind == 127:
                raise ValueError(f'Invalid FLAC metadata: {path}')
            blocks.append((kind, data))
            if header[0] & 128:
                break
        if blocks[0][0] != 0 or len(blocks[0][1]) != 34:
            raise ValueError(f'Invalid STREAMINFO: {path}')
        if stream.read(1) == b'':
            raise ValueError(f'No FLAC audio frames: {path}')
        return blocks, stream.tell() - 1


def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        if path.suffix.lower() != '.flac':
            continue
        if path.is_symlink() or not path.is_file():
            raise ValueError(f'Expected a regular FLAC file: {path}')
        relative = path.relative_to(root)
        key = relative.with_suffix('')
        if key.suffix.lower() == '.cdda':
            key = key.with_suffix('')
        if key in result:
            raise ValueError(f'Ambiguous filename: {relative}')
        result[key] = path
    return result


def fingerprint(path):
    info = path.stat()
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def main():
    source = args.source.resolve(strict=True)
    destination = args.destination.resolve(strict=True)
    if not source.is_dir() or not destination.is_dir():
        raise ValueError('Source and destination must be directories.')
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError('Source and destination folders must not overlap.')
    sources = inventory(source)
    targets = inventory(destination)
    if not sources:
        raise ValueError('No source FLAC files found.')
    missing = sources.keys() - targets.keys()
    if missing:
        raise ValueError('Missing destination FLAC files: ' + ', '.join(map(str, sorted(missing))))
    for key in sorted(targets.keys() - sources.keys()):
        print(f'[SKIP] No matching source: {targets[key]}', flush=True)
    plan = []
    # Validate every pair before changing any file.
    for key, src in sources.items():
        dst = targets[key]
        src_state, dst_state = fingerprint(src), fingerprint(dst)
        metadata(src)
        metadata(dst)
        if os.path.samefile(src, dst):
            raise ValueError(f'Source and destination refer to the same file: {dst}')
        plan.append((src, dst, src_state, dst_state))
    for src, dst, src_state, dst_state in plan:
        print(f'{src} -> {dst}', flush=True)
        if args.dry_run:
            continue
        if fingerprint(src) != src_state or fingerprint(dst) != dst_state:
            raise ValueError(f'File changed during processing: {src} / {dst}')
        source_blocks, _ = metadata(src)
        target_blocks, offset = metadata(dst)
        # Keep target STREAMINFO, seek tables, padding and application blocks.
        blocks = [block for block in target_blocks if block[0] not in (4, 6)]
        blocks += [block for block in source_blocks if block[0] in (4, 6)]
        pending = None
        try:
            with tempfile.NamedTemporaryFile(prefix='.copy_metadata.', suffix='.flac',
                                             dir=dst.parent, delete=False) as output:
                pending = Path(output.name)
                output.write(b'fLaC')
                for index, (kind, data) in enumerate(blocks):
                    flag = 128 if index == len(blocks) - 1 else 0
                    output.write(bytes([kind | flag]) + struct.pack('>I', len(data))[1:])
                    output.write(data)
                with dst.open('rb') as audio:
                    audio.seek(offset)
                    shutil.copyfileobj(audio, output, length=1024 * 1024)
                output.flush()
                os.fsync(output.fileno())
            shutil.copystat(dst, pending)
            if fingerprint(src) != src_state or fingerprint(dst) != dst_state:
                raise ValueError(f'File changed during processing: {src} / {dst}')
            os.replace(pending, dst)
            pending = None
        finally:
            if pending is not None:
                pending.unlink(missing_ok=True)
    print(f'{"Validated" if args.dry_run else "Updated"} {len(plan)} FLAC files.')


try:
    main()
except (OSError, ValueError) as error:
    print(f'[ERROR] {error}', file=sys.stderr)
    sys.exit(1)
except KeyboardInterrupt:
    sys.exit(130)
PY
