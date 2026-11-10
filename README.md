# strip-video-meta

Strips metadata from every video file in the current folder, at two layers:
in the current folder, without touching the media streams and without
changing the files' filesystem metadata (timestamps, attributes).

## Install

Put `strip-video-meta.ps1` and `strip-video-meta.cmd` side by side in any
folder on your PATH (the .cmd resolves the .ps1 relative to its own
location). Easiest: add this project folder to your PATH. Alternative:
keep a two-line shim .cmd on your PATH that runs the .ps1 by absolute
path.

## Usage

Ask for help with `-Help` (`--help`, `-h`, `-?` and `/?` all work from a
command prompt). Those spellings are intercepted in the `.cmd` shims and print
the usage summary. They have to be: PowerShell binds a bare `--help` or `-?` to
its own built-in `-Help` common parameter, lets the script run, and exits 0 —
so before that interception, asking for help in a folder of videos silently
stripped every file in it.

1. Make sure `ffmpeg` is on your PATH.
2. `cd` into the folder with your videos.
3. Run `strip-video-meta` (works from cmd and PowerShell).

    Stripping: my_video.mp4
    Skipping: clean_video.mp4 (no removable metadata)
    Done: 1 stripped, 1 skipped, 0 failed.
Add `-DryRun` to list what would happen without touching anything, `-Audit` to
print the metadata inventory of every file (container tags, chapters, in-band
units, and any codec-level limitation that applies), or `-NoVerify` to skip the
safety gates described under "How it works" (not recommended):

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
2. Probe with `ffprobe` and count the removable payload: container tags
   outside the inherent `ftyp` brand fields, chapters, and — for codecs with
   an in-band path — the user-data units in the video bitstream. If all three
   are zero, skip it: no rewrite, reported as `skipped`. A file ffprobe cannot
   read is reported failed and left untouched. With `-DryRun` or `-Audit`, the
   run reports and changes nothing.
3. Run ffmpeg with stream copy only (no re-encode): `-map 0`, `-map_metadata
   -1`, `-map_chapters -1`, one `-map_metadata:s:<type> -1` for every stream
   type present, the re-applied functional tags, the codec-scoped
   `-bsf:v filter_units=…`, `-fflags +bitexact`, `-c copy` — writing to
   `name.__strip_meta.ext` in the same folder (same volume).
4. Stamp the captured timestamps and attributes onto the temp file.
5. Replace the original with `Move-Item -Force` — an NTFS rename, not a
   copy. No duplicate videos are left behind.
6. Re-apply the attribute mask to the final file (see Implementation
   notes).

Three gates must pass before the result replaces the original:

1. ffmpeg exits 0.
2. The stream inventory is unchanged — count, type, codec, frame size, pixel
   format, sample rate, channel count — so no track can be silently dropped.
3. The decoded output is bit-identical: raw decoded video and audio are
   MD5-hashed for both files and must match. A wrong unit type (for example
   `filter_units` reading an MPEG-2 slice row as user data) changes pixels and
   is caught here.

If any gate fails, the temp file is deleted and the original is left
untouched; the file is counted as failed. `-NoVerify` skips gates 2 and 3.

## What gets removed / kept

Removed from the container:

- All global tags (title, artist, comment, encoder, …)
- All per-stream tags (track titles, per-track `encoder`, vendor strings),
  wiped per stream type with `-map_metadata:s:v -1` and friends. The old
  global-only `-map_metadata -1` left these behind — measured, 3 stream tags
  survived on an MP4 whose global tags were all gone.
- Chapters
- In-band units inside the video bitstream, per codec:
  - H.264 SEI NAL units (type 6) — where `x264 - core …` and the Kuaishou /
    Kling `kling-ai` marker live — via `-bsf:v filter_units=remove_types=6`.
    Measured on a Kling output: 2 SEI units → 0, the `kling` string gone,
    decoded frames bit-identical.
  - MPEG-1/2 `user_data` blocks (start code `0xB2`) via `remove_types=18`.
    Caveat: ffmpeg writes no user_data of its own and no sample carrying one
    could be produced, so this path is enabled from the type table and the
    measured filter behaviour, not from an end-to-end removal; the decode gate
    is what bounds a wrong mapping there. Measured separately: MPEG-PS stores
    no container tags at all, so a tag-only `.mpg` is correctly reported as
    having nothing removable.

Not removed:

- HEVC SEI units (NAL types 39 / 40). `filter_units` does remove them from an
  elementary stream (measured: 4 → 0 units, 144,068 → 134,680 bytes) but is a
  no-op on length-prefixed HEVC inside MP4 / MOV / MKV (elementary stream came
  back byte-identical). The tool counts them and says so rather than rewriting
  the file for nothing.
- Matroska's global `encoder` tag, which the muxer always writes. With
  `+bitexact` its value is the bare token `Lavf` — this tool's own signature,
  not the source file's, and no version number. `-metadata encoder=` does not
  delete it.
- VP8 / VP9 / AV1 / MPEG-4 part 2 / VC-1 / WMV / ProRes: no in-band producer
  field exists in these codecs, so there is nothing to remove.

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
- `metaudit.py` — audit harness: prints the full metadata inventory of any
  video file (container tags, per-stream tags, chapters, attachments, in-band
  SEI / user_data units with their decoded text payloads, producer strings).
  Run it before and after; the diff is what the tool removed. It is also the
  acceptance test for the rules in this README.

| File | Role |
|---|---|
| `strip-video-meta.ps1` | The actual script (PowerShell) |
| `strip-video-meta.cmd` | PATH shim — runs the script on the current folder |

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
- 2026-11-10 — In-band metadata added, after `metaudit.py` showed what the
  original version left behind: H.264 SEI units (the `kling-ai` / `x264 -
  core` markers), per-stream tags, and dropped tracks. Stream selection is now
  explicit, every stream type's tags are wiped, three verification gates guard
  every rewrite, and `-Audit` / `-NoVerify` exist. HEVC SEI is reported, not
  removed — measured no-op in length-prefixed containers.
  and which are already clean, without writing anything.

## License

MIT — see [LICENSE](LICENSE).
