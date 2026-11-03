# Paranoid Ripper

Bash utilities for ripping audio CDs, converting FLAC albums, and copying metadata.

I originally created these scripts around the early 2000s, and I still use them today.

| Script | Purpose |
| --- | --- |
| `prip.sh` | The **p stands for paranoid**: read a CD twice, verify the FLAC files, and compare decoded audio checksums. Discard the pregap (`track00`) after verification and eject the CD on success. Logs include a persistent `logs/summary.log`. |
| `norm.sh` | Convert albums stored in `flac` directories to sibling `mp3` and/or `ogg` directories, including tags and cover art. Does not normalize audio levels. Rename `trackXX.cdda.flac` to `trackXX.flac`; existing outputs are never overwritten. |
| `rencode.sh` | Rebuild enabled formats using `norm.sh`, keeping previous outputs until conversion succeeds. Select only paths containing a four-digit year followed by ` -`. |
| `cpmd.sh` | Replace FLAC tags and embedded pictures from another folder without re-encoding audio. Match relative paths and filenames, ignoring an optional `.cdda` suffix. Supports a dry run. |
| `msync.sh` | Use Babashka and rsync to sync FLAC or MP3 files, removing the format directory from destination paths while preserving artist/album directories. Source files and extra destination files are retained. |

## Examples

```bash
# Rip into a new directory; unreadable sectors are retried indefinitely.
bash prip.sh -m "/music/Artist/2026 - Album"

# Create MP3 and Ogg Vorbis copies (defaults: MP3 V0, Vorbis quality 6).
MP3=1 OGG=1 bash norm.sh -f "/music/Artist/2026 - Album"

# Rebuild MP3 copies in a library.
bash rencode.sh -f "/music"

# Preview metadata matches; remove -n to apply changes.
bash cpmd.sh -s "/original/flac" -d "/destination/flac" -n

# Preview an MP3 sync: Artist/Album/mp3/track.mp3 becomes Artist/Album/track.mp3.
# Remove -n to copy, or use -t flac to select FLAC files.
bash msync.sh -s "/music" -d "/portable/music" -t mp3 -n

```

## Requirements

Bash and standard Linux command-line tools. Depending on the script and enabled
formats: `cdparanoia`, `flac`/`metaflac`, `eject`, `lame`, `oggenc`, Babashka (`bb`),
and ImageMagick (for cover conversion). Use `-h` for each script's help.

`cpmd.sh` and `msync.sh` require Babashka, as does Ogg Vorbis cover embedding in
`norm.sh`. `msync.sh` also requires rsync 3.2.3 or later.

## License

Released under the [MIT License](LICENSE).
