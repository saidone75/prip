#!/usr/bin/env bash

# Author: Marco Marini
# Description: Generate a blacklist excluding every album in a music library.
# License: MIT (see LICENSE)
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
if [[ $# -ne 1 || ! -d $1 ]]; then
    printf 'Usage: %s MUSIC_DIRECTORY > msync.blacklist\n' "${0##*/}" >&2
    exit 1
fi
cat <<'HEADER'
## msync.bb album selection
## Lines starting with a single # EXCLUDE albums from synchronization.
## To sync an album, remove its leading #; uncommented album lines are enabled.
## Blank lines and lines starting with ## are ignored as instructions.
## Albums not listed are synchronized; an exclusion wins over a duplicate enabled entry.
## With --delete, excluded albums are removed from the destination for the selected format.
## Paths below are relative to the music directory; use the same source with msync.bb.

HEADER
find "$1" -type d \( -iname mp3 -o -iname flac \) -printf '%P\n' |
    sed -E 's#/?([mM][pP]3|[fF][lL][aA][cC])$##' |
    sed '/^$/d' |
    LC_ALL=C sort -u |
    sed 's/^/# /'
