# Paranoid Ripper

Bash utilities for ripping audio CDs, converting FLAC albums, and copying metadata.

I originally created these scripts around the early 2000s, and I still use them today.

| Script | Purpose |
| --- | --- |
| `prip.sh` | The **p stands for paranoid**: read a CD twice, verify the FLAC files, and compare decoded audio checksums. Discard the pregap (`track00`) after verification and eject the CD on success. Logs include a persistent `logs/summary.log`. |
| `norm.sh` | Convert albums stored in `flac` directories to sibling `mp3` and/or `ogg` directories, including tags and cover art. Does not normalize audio levels. Rename `trackXX.cdda.flac` to `trackXX.flac`; existing outputs are never overwritten. |
| `rebuild_mp3_ogg.sh` | Rebuild enabled formats using `norm.sh`, keeping previous outputs until conversion succeeds. Select only paths containing a four-digit year followed by ` -`. |
| `copy_metadata.sh` | Replace FLAC tags and embedded pictures from another folder without re-encoding audio. Match relative paths and filenames, ignoring an optional `.cdda` suffix. Supports a dry run. |

## Examples

```bash
# Rip into a new directory; unreadable sectors are retried indefinitely.
bash prip.sh -m "/music/Artist/2026 - Album"

# Create MP3 and Ogg Vorbis copies (defaults: MP3 V0, Vorbis quality 6).
MP3=1 OGG=1 bash norm.sh -f "/music/Artist/2026 - Album"

# Rebuild MP3 copies in a library.
bash rebuild_mp3_ogg.sh -f "/music"

# Preview metadata matches; remove -n to apply changes.
bash copy_metadata.sh -s "/original/flac" -d "/destination/flac" -n

```

## Requirements

Bash and standard Linux command-line tools. Depending on the script and enabled
formats: `cdparanoia`, `flac`/`metaflac`, `eject`, `lame`, `oggenc`, Python 3,
and ImageMagick (for cover conversion). Use `-h` for each script's help.

## License

Released under the [MIT License](LICENSE). Original GSK and author references
are retained in the relevant script headers.
