# Paranoid Ripper

Bash utilities for ripping audio CDs, converting FLAC albums, and copying metadata.

I originally created these scripts around the early 2000s but I still use them today.

| Script       | Purpose                                                    |
|--------------|------------------------------------------------------------|
| `prip.sh`    | Rip CDs to FLAC, verifying two independent reads.          |
| `norm.sh`    | Convert FLAC albums to MP3/Vorbis with tags and cover art. |
| `rencode.sh` | Rebuild MP3/Vorbis albums using `norm.sh`.                 |
| `cpmd.sh`    | Copy FLAC tags and cover art without re-encoding.          |
| `msync.sh`   | Sync FLAC/MP3 files, preserving artist/album folders.      |

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
