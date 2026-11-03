#!/bin/bash

# GlaxoSmithKline R&D Verona, Italy
# Author: Marco Marini
# Description: Paranoid CD ripper; compare two independent reads before removing WAVs.
# License: MIT (see LICENSE)
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
shopt -s nullglob nocaseglob

DEBUG=${DEBUG:-1}
workdir=
summary=
started=$SECONDS
stage=initialization
verified=no
failure=

write_summary() {
    local status=$? logfile
    trap - EXIT ERR
    if [[ -n $summary ]]; then
        {
            for logfile in "$workdir"/logs/trial-{a,b}/cdparanoia.log; do
                [[ -f $logfile ]] || continue
                printf '\nRead events: %s\n' "${logfile#"$workdir"/logs/}"
                awk '
                    /\[jitter\]/ { jitter++ }
                    /\[skip\]/ { skips++ }
                    /\[readerr\]/ { readerrors++ }
                    END {
                        printf "Jitter callbacks: %d\nSkip callbacks: %d\nRead-error callbacks: %d\n", jitter, skips, readerrors
                    }
                ' "$logfile"
            done
            printf '\nAudio comparison and FLAC verification passed: %s\n' "$verified"
            printf 'Final stage: %s\nExit status: %s\n' "$stage" "$status"
            [[ -z $failure ]] || printf 'Error: %s\n' "$failure"
            printf 'Total elapsed seconds: %s\n' "$((SECONDS - started))"
            printf 'Finished: %(%Y-%m-%dT%H:%M:%S%z)T\n' -1
        } >> "$summary" || printf '[WARN] Could not finish summary: %s\n' "$summary" >&2
        printf '[INFO] Summary: %s\n' "$summary"
    fi
    exit "$status"
}
trap write_summary EXIT

info() { printf '[INFO] %s\n' "$*"; }
debug() { if [[ $DEBUG == 1 ]]; then printf '[DEBUG] %s\n' "$*"; fi; }
fatal() { failure=$*; printf '[FATAL] %s\n' "$*" >&2; exit 1; }

on_error() {
    local status=$?
    trap - ERR
    failure="Command failed (exit $status), line $1."
    printf '[FATAL] Command failed (exit %s), line %s.\n' "$status" "$1" >&2
    if [[ -n $workdir ]]; then
        printf 'Files and logs retained in: %s\n' "$workdir" >&2
    fi
    exit "$status"
}
trap 'on_error "$LINENO"' ERR
trap 'fatal "Interrupted; available files and logs are retained in ${workdir:-the current directory}."' INT TERM HUP

usage() {
    printf 'Usage: %s -m destination_directory\n' "${0##*/}"
    printf 'Read a CD twice, encode and verify FLAC files, and compare decoded audio.\n'
    printf 'Discard track00 (the first-track pregap) after successful verification.\n'
    printf 'The destination must not already exist. Logs are kept under destination/logs.\n'
    printf 'A persistent summary is saved as destination/logs/summary.log.\n'
}

mainproject=
while getopts ':m:h' opt; do
    case $opt in
        m) mainproject=$OPTARG ;;
        h) usage; exit 0 ;;
        :) fatal "Option -$OPTARG requires an argument." ;;
        \?) usage >&2; fatal "Unknown option: -$OPTARG" ;;
    esac
done
shift "$((OPTIND - 1))"
[[ -n $mainproject && $# -eq 0 ]] || { usage >&2; exit 1; }

for dependency in cdparanoia flac nice sha256sum cmp mkdir mv rm rmdir tee awk eject; do
    command -v "$dependency" >/dev/null 2>&1 || fatal "Required command not found: $dependency"
done

# Atomic creation prevents reusing a destination containing previous results.
mkdir -- "$mainproject"
cd -- "$mainproject"
workdir=$PWD
mkdir -- logs
summary="$workdir/logs/summary.log"
{
    printf 'CD rip summary\nDestination: %s\n' "$workdir"
    printf 'Started: %(%Y-%m-%dT%H:%M:%S%z)T\n' -1
    printf 'Reader command: cdparanoia -vBze\n'
} > "$summary"
info "${0##*/} started. Destination: $workdir"

for trial in trial-a trial-b; do
    mkdir -- "$trial" "$trial/flac" "logs/$trial"
    info "Reading CD: $trial"
    stage="reading $trial"
    read_started=$SECONDS
    printf '\n%s: reading started\n' "$trial" >> "$summary"
    # Retry indefinitely instead of skipping sectors; retain each read's diagnostics.
    (cd -- "$trial"; cdparanoia -vBze) 2>&1 |
        tee "logs/$trial/cdparanoia.log" |
        awk -v trial="$trial" '
            /outputting to / {
                track = $0
                sub(/^.*outputting to /, "", track)
                printf "[INFO] Reading %s: %s\n", trial, track
                fflush()
            }
        '
    printf '%s: read completed in %s seconds\n' "$trial" "$((SECONDS - read_started))" >> "$summary"
    stage="encoding and verifying $trial"
    files=("$trial"/*.wav)
    ((${#files[@]} > 0)) || fatal "No WAV tracks produced by $trial; files and logs retained in $workdir."
    : > "$trial/audio.sha256"
    for file in "${files[@]}"; do
        [[ -f $file && -s $file ]] || fatal "Invalid or empty track: $file"
        name=${file##*/}
        stem=${name%.*}
        output="$trial/flac/$stem.flac"
        log="logs/$trial/$stem.log"
        debug "Encoding $file"
        nice -n 19 flac --verify --output-name="$output" -- "$file" >"$log" 2>&1
        flac --test -- "$output" >>"$log" 2>&1
        # Hash raw decoded samples, independent of FLAC metadata and compression.
        checksum=$(flac --decode --stdout --force-raw-format --endian=little --sign=signed -- "$output" 2>>"$log" | sha256sum)
        checksum=${checksum%% *}
        printf '%s  %s\n' "$checksum" "$name" >> "$trial/audio.sha256"
    done
    printf '%s: %s tracks encoded and verified (including pregap if present)\n' "$trial" "${#files[@]}" >> "$summary"
done

# Manifests include every track name and its audio checksum, in glob order.
stage='comparing audio'
if ! cmp -s -- trial-a/audio.sha256 trial-b/audio.sha256; then
    fatal "Track lists or decoded audio differ; all files and logs retained in $workdir."
fi
info 'All tracks match and FLAC integrity checks passed.'
verified=yes
stage='publishing and cleaning up'

# Publish the verified output before deleting either set of source WAVs.
mv -- trial-a/flac ./flac
mv -- trial-a/audio.sha256 logs/trial-a/audio.sha256
mv -- trial-b/audio.sha256 logs/trial-b/audio.sha256
for pregap in flac/track00.cdda.flac flac/track00.flac \
    logs/trial-{a,b}/track00.cdda.log logs/trial-{a,b}/track00.log; do
    if [[ -f $pregap ]]; then
        rm -- "$pregap"
        info "Discarded pregap: $pregap"
        printf 'Discarded pregap file: %s\n' "$pregap" >> "$summary"
    fi
done
rm -- trial-a/*.wav trial-b/*.wav trial-b/flac/*.flac
rmdir -- trial-b/flac trial-a trial-b
output_files=(flac/*.flac)
printf 'Final FLAC tracks: %s\n' "${#output_files[@]}" >> "$summary"
info "${0##*/} done. FLAC files: $workdir/flac"
info 'Ejecting CD.'
stage='ejecting CD'
eject
printf 'CD ejected successfully\n' >> "$summary"
stage=completed
