#!/usr/bin/env bash

# Author: Marco Marini
# Description: Play one random audio file, then exit VLC.
# License: MIT (see LICENSE)
# SPDX-License-Identifier: MIT

set -Eeuo pipefail

fatal() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
usage() {
    printf 'Usage: %s [folder]\n' "${0##*/}"
    printf 'Play one random audio file recursively from folder (default: current directory).\n'
}
if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit 0
fi
[[ $# -le 1 ]] || { usage >&2; exit 1; }
folder=${1:-.}
[[ -d $folder ]] || fatal "Directory not found: $folder"
for tool in cvlc find shuf mktemp rm; do
    command -v "$tool" >/dev/null 2>&1 || fatal "Required command not found: $tool"
done

listing=$(mktemp)
trap 'rm -f -- "$listing"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
cd -- "$folder"
# Absolute paths also prevent filenames beginning with '-' from becoming VLC options.
find "$PWD" -type f \( -iname '*.aif' -o -iname '*.aiff' -o -iname '*.mp3' \
    -o -iname '*.ogg' -o -iname '*.wav' -o -iname '*.flac' \) -print0 > "$listing"
tracks=()
mapfile -d '' -t tracks < "$listing"
((${#tracks[@]})) || fatal "No supported audio files found in: $PWD"
# shuf handles the entire library, without the range limitation of Bash RANDOM.
index=$(shuf -i "0-$((${#tracks[@]} - 1))" -n 1)
printf '[INFO] Playing track %s of %s: %s\n' "$((index + 1))" "${#tracks[@]}" "${tracks[$index]}"

eq_args=(--audio-filter param_eq --param-eq-lowf=500 --param-eq-lowgain=3
         --param-eq-highf=1800 --param-eq-highgain=-3)
cvlc -I dummy "${eq_args[@]}" --play-and-exit -- "${tracks[$index]}"
