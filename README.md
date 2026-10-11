# strip-video-meta

Strips container metadata (global tags + chapters) from every video file
in the current folder, without touching the media streams and without
changing the files' filesystem metadata (timestamps, attributes).

## Usage

1. Make sure `ffmpeg` is on your PATH.
2. `cd` into the folder with your videos.
3. Run `strip-video-meta` (works from cmd and PowerShell).

    Stripping: my_video.mp4
    Skipping: clean_video.mp4 (no removable metadata)
    Done: 1 stripped, 1 skipped, 0 failed.
Add `-DryRun` to list what would happen without touching anything:

    Would strip: my_video.mp4
    Skipping: clean_video.mp4 (no removable metadata)
    Dry run: 1 would be stripped, 1 have no removable metadata.

Extensions processed: `mp4 mkv avi mov m4v webm ts flv wmv m2ts mpg
mpeg 3gp asf vob`. Only the current folder is scanned (no recursion).

## How it works

For each video, in this order:

1. Capture the file's creation time, last write time, last access time,
   and NTFS attributes **before** anything reads it (a read refreshes
   the access time).
2. Pre-check with `ffprobe` (metadata-only read): if the file holds
   only the inherent `ftyp` brand tags and no chapters, skip it — no
   rewrite, reported as `skipped`. (If ffprobe fails, the file is
   still passed to the real attempt below. With `-DryRun`, the run
   stops here and reports the result; nothing is rewritten.)
3. Run ffmpeg with stream copy only (no re-encode):
   `-map_metadata -1 -map_chapters -1 -fflags +bitexact -c copy`,
   writing to `name.__strip_meta.ext` in the same folder (same volume).
4. Stamp the captured timestamps and attributes onto the temp file.
5. Replace the original with `Move-Item -Force` — an NTFS rename, not a
   copy. No duplicate videos are left behind.
6. Re-apply the attribute mask to the final file (see Implementation
   notes).

If ffmpeg fails, the temp file is deleted and the original is left
untouched; the file is counted as failed.

## What gets removed / kept

Removed from the container:

- All global tags (title, artist, comment, encoder, …)
- Chapters
- The muxer's own `encoder=Lavf…` tag (suppressed via `+bitexact`)

Kept:

- All media streams, bit-identical (stream copy)
- MP4 `ftyp` brand entries (`major_brand`, `compatible_brands`,
  `minor_version`) — inherent to the format, not metadata
- Filesystem: creation time, last write time, last access time
- File attributes: `Archive`, `Hidden`, `ReadOnly`, `System`,
  `NotContentIndexed`

Not preserved (deliberately):

- Compressed / Encrypted NTFS flags (applying them rewrites the whole
  file)
- Alternate data streams, NTFS extended attributes
- The security descriptor (the temp file inherits the folder's ACL,
  which the original usually already shares)

## Files

| File | Role |
|---|---|
| `strip-video-meta.ps1` | The actual script (PowerShell) |
| `strip-video-meta.cmd` | Local shim — runs the script on the current folder |

## Implementation notes

- `Rename-Item -Force` cannot replace an existing file (observed on
  Windows PowerShell 5.1); the overwrite uses `Move-Item -Force`, which
  handles existing (even hidden) destinations.
- `Move-Item -Force` leaves the `Archive` bit set when it overwrites, so
  the original's attribute mask is re-applied to the final file.
- The temp file is created in the same folder as the source so the
  final replace is a same-volume rename (zero extra data movement).

## Testing

Test files are generated with ffmpeg's libavfilter test sources — no
footage required. The command synthesizes a 1-second 320×240 test
pattern (`testsrc`, pixels computed from the frame/time numbers) and a
440 Hz tone (`sine`), encodes them to H.264/AAC, and injects known
metadata tags that must disappear:

    ffmpeg -y -f lavfi -i testsrc=duration=1:size=320x240:rate=10 ^
           -f lavfi -i sine=frequency=440:duration=1 ^
           -c:v libx264 -preset ultrafast -c:a aac ^
           -metadata title=Leak -metadata artist=Leak ^
           test.mp4

The result is a deterministic ~30 KB disposable file with real,
verifiable streams. Before running the tool, the test file is given
distinctive timestamps (e.g. 2019/2022) and attributes (`Hidden`,
`ReadOnly`); a passing run leaves those byte-for-byte intact, reduces
the tags to the inherent `ftyp` brand entries (verified with
`ffprobe`), and leaves exactly one file in the folder.
A second run over the same file must report it as `skipped` and leave
it byte-for-byte identical (verified by hash).

## History

- 2026-10-10 — Initial version: a single `.cmd` on the PATH that
  stripped container tags. The replacement file was created fresh,
  which reset the file's timestamps.
- 2026-10-11 — Moved to this project. Logic moved to
  `strip-video-meta.ps1`; the `.cmd` files became shims. The
  replacement file now keeps the original's creation/write/access times
  and file attributes. Overwrite mechanism fixed (`Move-Item -Force` +
  attribute re-apply); verified with hidden and read-only test files.
- 2026-10-11 — Added the ffprobe pre-check: files with no removable
  metadata are skipped without being rewritten and reported as
  `skipped` (re-running over an already-clean folder now costs zero
  writes).
- 2026-10-11 — Added `-DryRun`: reports which files would be stripped
  and which are already clean, without writing anything.
