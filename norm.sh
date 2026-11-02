#!/bin/bash

# GlaxoSmithKline R&D Verona, Italy
# Author: Marco Marini
# Description: Convert FLAC albums to MP3/Vorbis. Does not normalize audio levels.
# License: MIT (see LICENSE)
# SPDX-License-Identifier: MIT

set -Eeuo pipefail

DEBUG=${DEBUG:-1}
MP3=${MP3:-1}
OGG=${OGG:-0}
MP3_QUALITY=${MP3_QUALITY:-0}
OGG_QUALITY=${OGG_QUALITY:-6}
EXIT_ON_MISSING_ALBUM_META=${EXIT_ON_MISSING_ALBUM_META:-1}
tmpdir=
pending=
info() { printf '[INFO] %s\n' "$*"; }
debug() { if [[ $DEBUG == 1 ]]; then printf '[DEBUG] %s\n' "$*"; fi; }
fatal() { printf '[FATAL] %s\n' "$*" >&2; exit 1; }
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n $pending ]]; then rm -f -- "$pending" || :; fi
    if [[ -n $tmpdir ]]; then rm -rf -- "$tmpdir" || :; fi
    exit "$status"
}
trap cleanup EXIT
trap 'printf "[FATAL] Command failed at line %s.\n" "$LINENO" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM HUP
usage() {
    printf 'Usage: %s -f folder\n' "${0##*/}"
    printf 'Find FLAC directories recursively and create sibling mp3/ogg directories.\n'
    printf 'Existing outputs are never overwritten. Source audio and metadata are unchanged.\n'
    printf 'Rename trackXX.cdda.flac to trackXX.flac (XX = two digits), without overwriting.\n'
    printf 'Environment: MP3=1 OGG=0 MP3_QUALITY=2 OGG_QUALITY=6 DEBUG=1\n'
    printf 'Set EXIT_ON_MISSING_ALBUM_META=0 to allow missing ALBUM tags.\n'
}
folder=
while getopts ':f:h' opt; do
    case $opt in
        f) folder=$OPTARG ;;
        h) usage; exit 0 ;;
        :) fatal "Option -$OPTARG requires an argument." ;;
        \?) usage >&2; fatal "Unknown option: -$OPTARG" ;;
    esac
done
shift "$((OPTIND - 1))"
[[ -n $folder && $# -eq 0 ]] || { usage >&2; exit 1; }
[[ -d $folder ]] || fatal "Directory not found: $folder"
for flag in MP3 OGG DEBUG EXIT_ON_MISSING_ALBUM_META; do
    [[ ${!flag} == 0 || ${!flag} == 1 ]] || fatal "$flag must be 0 or 1."
done
[[ $MP3 == 1 || $OGG == 1 ]] || fatal 'Enable at least one output format.'
[[ $MP3_QUALITY =~ ^[0-9]$ ]] || fatal 'MP3_QUALITY must be an integer from 0 to 9.'
[[ $OGG_QUALITY =~ ^(-1|[0-9]|10)$ ]] || fatal 'OGG_QUALITY must be an integer from -1 to 10.'
dependencies=(flac metaflac find mktemp mkdir ln rm)
[[ $MP3 == 0 ]] || dependencies+=(lame)
[[ $OGG == 0 ]] || dependencies+=(oggenc python3)
for tool in "${dependencies[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || fatal "Required command not found: $tool"
done
if command -v magick >/dev/null 2>&1; then
    image_command=(magick)
elif command -v convert >/dev/null 2>&1; then
    image_command=(convert)
else
    image_command=()
fi
cd -- "$folder"
tmpdir=$(mktemp -d)
find "$PWD" -type d -iname flac -print0 > "$tmpdir/folders"
files=()
originals=()
declare -A planned=()
while IFS= read -r -d '' directory; do
    # Only direct children: nested albums must not collide by basename.
    find "$directory" -maxdepth 1 -type f -iname '*.flac' -print0 > "$tmpdir/files"
    while IFS= read -r -d '' file; do
        original=$file
        parent=${directory%/*}
        name=${file##*/}
        if [[ $name =~ ^track([0-9]{2})\.cdda\.flac$ ]]; then
            name="track${BASH_REMATCH[1]}.flac"
            file="$directory/$name"
            [[ ! -e $file && ! -L $file ]] || fatal "Rename destination already exists: $file"
        fi
        originals+=("$original")
        files+=("$file")
        stem=${name%.*}
        for format in mp3 ogg; do
            [[ $format != mp3 || $MP3 == 1 ]] || continue
            [[ $format != ogg || $OGG == 1 ]] || continue
            output="$parent/$format/$stem.$format"
            [[ ! -e $output && ! -L $output ]] || fatal "Output already exists: $output"
            [[ ! ${planned[$output]+exists} ]] || fatal "Multiple sources map to: $output"
            planned["$output"]=1
        done
    done < "$tmpdir/files"
done < "$tmpdir/folders"
((${#files[@]})) || fatal 'No FLAC tracks found in FLAC directories.'

# Rename only after every source and output path has passed preflight.
# Linking first prevents an existing file from being overwritten in a race.
for index in "${!files[@]}"; do
    [[ ${originals[$index]} != "${files[$index]}" ]] || continue
    ln -T -- "${originals[$index]}" "${files[$index]}"
    rm -- "${originals[$index]}"
    info "Renamed ${originals[$index]} -> ${files[$index]}"
done

# Publish with a hard link in the same directory: atomic, without overwrite.
publish() {
    [[ -s $pending ]] || fatal "Encoder produced an empty file: $output"
    ln -T -- "$pending" "$output"
    rm -- "$pending"
    pending=
}
for file in "${files[@]}"; do
    debug "Processing $file"
    directory=${file%/*}
    parent=${directory%/*}
    name=${file##*/}
    stem=${name%.*}
    metaflac --export-tags-to="$tmpdir/tags" -- "$file"
    declare -A tags=()
    ogg_args=()
    while IFS= read -r tag || [[ -n $tag ]]; do
        [[ $tag == *=* ]] || continue
        key=${tag%%=*}
        value=${tag#*=}
        key=${key^^}
        [[ ${tags[$key]+exists} ]] || tags["$key"]=$value
        # Preserve textual tags, but exclude pictures and stale gain data.
        case $key in
            METADATA_BLOCK_PICTURE|COVERART|COVERARTMIME|REPLAYGAIN_*|R128_*) ;;
            *) ogg_args+=(-c "$tag") ;;
        esac
    done < "$tmpdir/tags"
    [[ -n ${tags[ALBUM]:-} || $EXIT_ON_MISSING_ALBUM_META == 0 ]] || fatal "Missing ALBUM tag: $file"
    flac --test -- "$file"
    cover=
    metaflac --list --block-type=PICTURE -- "$file" > "$tmpdir/pictures"
    if [[ -s $tmpdir/pictures ]]; then
        ((${#image_command[@]})) || fatal 'ImageMagick is required for embedded covers.'
        metaflac --export-picture-to="$tmpdir/source-picture" -- "$file"
        cover="$tmpdir/cover.jpg"
        "${image_command[@]}" "$tmpdir/source-picture[0]" -auto-orient -thumbnail '512x512>' -background white -alpha remove -alpha off -strip -quality 80 "$cover"
    fi
    flac --decode --force --output-name="$tmpdir/audio.wav" -- "$file"
    if [[ $MP3 == 1 ]]; then
        mkdir -p -- "$parent/mp3"
        output="$parent/mp3/$stem.mp3"
        pending=$(mktemp "$parent/mp3/.norm.XXXXXXXX.mp3")
        args=(-V "$MP3_QUALITY" --id3v2-only --id3v2-utf16)
        for mapping in 'TITLE:TIT2' 'ARTIST:TPE1' 'ALBUM:TALB' 'ALBUMARTIST:TPE2' 'DATE:TDRC' 'GENRE:TCON' 'TRACKNUMBER:TRCK' 'DISCNUMBER:TPOS' 'COMPOSER:TCOM' 'COMMENT:COMM'; do
            key=${mapping%%:*}
            frame=${mapping#*:}
            value=${tags[$key]:-}
            [[ -n $value ]] || continue
            if [[ $key == TRACKNUMBER && $value != */* && -n ${tags[TRACKTOTAL]:-${tags[TOTALTRACKS]:-}} ]]; then
                value+="/${tags[TRACKTOTAL]:-${tags[TOTALTRACKS]}}"
            elif [[ $key == DISCNUMBER && $value != */* && -n ${tags[DISCTOTAL]:-${tags[TOTALDISCS]:-}} ]]; then
                value+="/${tags[DISCTOTAL]:-${tags[TOTALDISCS]}}"
            fi
            if [[ $key == COMMENT ]]; then args+=(--tc "$value"); else args+=(--tv "$frame=$value"); fi
        done
        [[ -z $cover ]] || args+=(--ti "$cover")
        lame "${args[@]}" "$tmpdir/audio.wav" "$pending"
        publish
    fi
    if [[ $OGG == 1 ]]; then
        if [[ -n $cover ]]; then
            picture=$(python3 - "$cover" <<'PY'
import base64, pathlib, struct, sys
image = pathlib.Path(sys.argv[1]).read_bytes()
def uint(n): return struct.pack('>I', n)
# Zero dimensions/depth indicate unspecified values in the picture block.
block = uint(3) + uint(10) + b'image/jpeg' + uint(0) + uint(0)*4 + uint(len(image)) + image
print(base64.b64encode(block).decode('ascii'))
PY
)
            ogg_args+=(-c "METADATA_BLOCK_PICTURE=$picture")
        fi
        mkdir -p -- "$parent/ogg"
        output="$parent/ogg/$stem.ogg"
        pending=$(mktemp "$parent/ogg/.norm.XXXXXXXX.ogg")
        oggenc -q "$OGG_QUALITY" "${ogg_args[@]}" -o "$pending" "$tmpdir/audio.wav"
        publish
    fi
done
info "Converted ${#files[@]} tracks successfully."
