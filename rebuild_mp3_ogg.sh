#!/bin/bash
# Rebuild enabled formats through norm.sh, retaining old outputs until success.
set -Eeuo pipefail

MP3=${MP3:-1}
OGG=${OGG:-0}
DEBUG=${DEBUG:-1}
export MP3 OGG DEBUG
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
NORM_SCRIPT=${NORM_SCRIPT:-$script_dir/norm.sh}
stage=
album=
formats=()
backed_up=()
installed=()
info() { printf '[INFO] %s\n' "$*"; }
fatal() { printf '[FATAL] %s\n' "$*" >&2; exit 1; }
cleanup() {
    local status=$? format failed=0
    trap - EXIT INT TERM HUP
    # Roll back an interrupted/failed publication before removing staging data.
    for format in "${installed[@]}"; do
        rm -rf -- "$album/$format" || failed=1
    done
    for format in "${backed_up[@]}"; do
        if [[ ! -e $album/$format && ! -L $album/$format ]]; then
            mv -T -- "$stage/previous-$format" "$album/$format" || failed=1
        else
            failed=1
        fi
    done
    if [[ -n $stage ]]; then
        if ((failed)); then
            printf '[FATAL] Recovery required; backups retained in %s\n' "$stage" >&2
        else
            rm -rf -- "$stage" || failed=1
        fi
    fi
    if ((failed)); then status=1; fi
    exit "$status"
}
trap cleanup EXIT
trap 'printf "[FATAL] Command failed at line %s.\n" "$LINENO" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM HUP
usage() {
    printf 'Usage: %s -f library_directory\n' "${0##*/}"
    printf 'Rebuild albums containing a FLAC directory, using the adjacent norm.sh.\n'
    printf 'Only paths containing a four-digit year followed by " -" are selected.\n'
    printf 'Old outputs are replaced only after the album converts successfully.\n'
    printf 'Environment: MP3=1 OGG=0 MP3_QUALITY=2 OGG_QUALITY=6 DEBUG=1\n'
    printf 'Disabled formats and source FLAC files are left unchanged.\n'
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
[[ -f $NORM_SCRIPT ]] || fatal "norm.sh not found: $NORM_SCRIPT"
# Resolve before entering the library, including relative overrides.
NORM_SCRIPT=$(realpath -- "$NORM_SCRIPT")
for flag in MP3 OGG DEBUG; do
    [[ ${!flag} == 0 || ${!flag} == 1 ]] || fatal "$flag must be 0 or 1."
done
[[ $MP3 == 0 ]] || formats+=(mp3)
[[ $OGG == 0 ]] || formats+=(ogg)
((${#formats[@]})) || fatal 'Enable at least one output format.'
cd -- "$folder"
listing=$(mktemp)
# Keep discovery outside staging and capture find errors.
if ! find "$PWD" -type d -iname flac -print0 > "$listing"; then
    rm -f -- "$listing"
    fatal 'Unable to scan the library.'
fi
mapfile -d '' -t discovered < "$listing"
rm -- "$listing"
directories=()
for directory in "${discovered[@]}"; do
    # Preserve the original library selection rule (applied to the full path).
    if [[ $directory =~ [0-9]{4}\ - ]]; then
        directories+=("$directory")
    fi
done
((${#directories[@]})) || fatal 'No FLAC directories match the year filter (YYYY -).'
declare -A seen=()
for directory in "${directories[@]}"; do
    album=${directory%/*}
    [[ ! ${seen[$album]+exists} ]] || fatal "Multiple FLAC directories in album: $album"
    seen["$album"]=1
    for format in "${formats[@]}"; do
        [[ ! -L $album/$format ]] || fatal "Output directory is a symbolic link: $album/$format"
        [[ ! -e $album/$format || -d $album/$format ]] || fatal "Output is not a directory: $album/$format"
    done
done
count=0
for directory in "${directories[@]}"; do
    album=${directory%/*}
    info "Rebuilding $album"
    stage=$(mktemp -d "$album/.rebuild.XXXXXXXX")
    mkdir -- "$stage/flac"
    find "$directory" -maxdepth 1 -type f -iname '*.flac' -print0 > "$stage/sources"
    tracks=0
    while IFS= read -r -d '' source; do
        # Same filesystem: no audio copy and no changes to the source inode.
        ln -- "$source" "$stage/flac/${source##*/}"
        tracks=$((tracks + 1))
    done < "$stage/sources"
    ((tracks > 0)) || fatal "No tracks in $directory"
    bash "$NORM_SCRIPT" -f "$stage"
    for format in "${formats[@]}"; do
        [[ -d $stage/$format ]] || fatal "Converter did not produce $format output."
    done
    for format in "${formats[@]}"; do
        if [[ -e $album/$format || -L $album/$format ]]; then
            # Register before moving so an interrupt cannot lose the backup.
            backed_up+=("$format")
            mv -T -- "$album/$format" "$stage/previous-$format"
        fi
        installed+=("$format")
        mv -T -- "$stage/$format" "$album/$format"
    done
    # Publication complete: subsequent cleanup may remove the backups.
    installed=()
    backed_up=()
    rm -rf -- "$stage"
    stage=
    count=$((count + 1))
done
info "Rebuilt $count albums successfully."
