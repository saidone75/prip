#!/usr/bin/env bash

# Author: Marco Marini
# Description: Refresh album selection, preserving existing choices and excluding new albums.
# License: MIT (see LICENSE)
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
usage() {
    printf 'Usage: %s [MUSIC_DIRECTORY]\n' "${0##*/}"
    printf 'Default source: current directory. Write msync.blacklist in the current directory.\n'
    printf 'Back up an existing file to msync.blacklist.bak (replacing the previous backup).\n'
    printf 'Merge existing choices (or .bak if missing), remove absent albums, and sort by album path.\n'
}
if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit 0
fi
library=${1:-.}
if [[ $# -gt 1 || ! -d $library ]]; then
    usage >&2
    exit 1
fi
output=msync.blacklist
backup="$output.bak"
for path in "$output" "$backup"; do
    if [[ -L $path || ( -e $path && ! -f $path ) ]]; then
        printf '[ERROR] Expected a regular file: %s\n' "$path" >&2
        exit 1
    fi
done
merge_source=
if [[ -f $output ]]; then
    merge_source=$output
elif [[ -f $backup ]]; then
    merge_source=$backup
fi
pending=$(mktemp .blacklist-all.XXXXXXXX)
trap 'rm -f -- "$pending"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
{
cat <<'HEADER'
## msync.bb album selection
## Lines starting with a single # EXCLUDE albums from synchronization.
## To sync an album, remove its leading #; uncommented album lines are enabled.
## Blank lines and lines starting with ## are ignored as instructions.
## Albums not listed are synchronized; an exclusion wins over a duplicate enabled entry.
## With --delete, excluded albums are removed from the destination for the selected format.
## Paths below are relative to the music directory; use the same source with msync.bb.
## Existing choices are preserved; new albums are excluded and absent albums are removed.

HEADER
find "$library" -type d \( -iname mp3 -o -iname flac \) -printf '%P\n' |
    sed -E 's#/?([mM][pP]3|[fF][lL][aA][cC])$##' |
    sed '/^$/d' |
    LC_ALL=C sort -u |
    BLACKLIST_MERGE_SOURCE="$merge_source" awk '
        BEGIN {
            previous = ENVIRON["BLACKLIST_MERGE_SOURCE"]
            if (previous != "") {
                while ((status = (getline line < previous)) > 0) {
                    sub(/^[[:space:]]+/, "", line)
                    sub(/[[:space:]]+$/, "", line)
                    if (line == "" || line ~ /^##/) continue
                    excluded = (line ~ /^#/)
                    sub(/^#[[:space:]]*/, "", line)
                    sub(/\/+$/, "", line)
                    if (line == "") continue
                    # An exclusion wins if an album has conflicting duplicate entries.
                    if (!(line in choices) || excluded) choices[line] = excluded
                }
                close(previous)
                if (status < 0) exit 1
            }
        }
        {
            album = $0
            # Match the same relative paths and album names accepted by msync.bb.
            known = 0
            excluded = 0
            path = album
            while (path != "") {
                name = path
                sub(/^.*\//, "", name)
                if (path in choices) { known = 1; excluded = excluded || choices[path] }
                if (name in choices) { known = 1; excluded = excluded || choices[name] }
                if (path !~ /\//) break
                sub(/\/[^/]*$/, "", path)
            }
            print ((!known || excluded) ? "# " : "") album
        }
    '
} > "$pending"
if [[ -f $output ]]; then
    cp -p -- "$output" "$backup"
    chmod --reference="$output" "$pending"
    printf '[INFO] Previous blacklist backed up to %s\n' "$backup"
fi
mv -T -- "$pending" "$output"
printf '[INFO] Blacklist written to %s\n' "$output"
