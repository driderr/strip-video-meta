<#
strip-video-meta.ps1 - strip container metadata AND in-band producer metadata
from every video file in the current folder.

Two layers of metadata exist and this tool handles both:

1. Container metadata: global tags, per-stream tags, chapters, and cover or
   attachment descriptors. Removed with -map_metadata for the file and for
   every stream type, plus -map_chapters -1.

2. In-band metadata: units inside the compressed video bitstream itself, which
   no container-level tool can see. H.264 carries them in SEI NAL units
   (type 6); MPEG-1/2 video carries them in user_data blocks (start code 0xB2).
   Removed with -bsf:v filter_units, scoped to the one unit type that means
   "user data" in that codec.

Codec scope for layer 2, measured on ffmpeg 7.x (see README "Verification"):
  h264                SEI removable in every container (types: 6)
  mpeg1video/mpeg2    user_data maps to filter_units type 18 (0xB2 & 0x1F).
                      The filter is proven to act on MPEG-2 packets, but no
                      test file holding real user_data could be produced, so
                      this path rests on the type table plus the decode gate,
                      not on a measured end-to-end removal.
  hevc                SEI live in NAL types 39/40. filter_units works on an
                      elementary stream but is a NO-OP on length-prefixed HEVC
                      inside MP4/MOV/MKV, so HEVC is reported, not rewritten.
  vp8/vp9/av1/mpeg4/vc1/wmv/prores  no in-band producer field exists.
  Colour, HDR and aspect-ratio signalling is deliberately NOT touched: it is
  not identifying, and removing it changes how the picture looks.

Safety: every rewritten file must pass three gates before it replaces the
original, or the original is kept and the file is reported FAILED:
  a. ffmpeg exits 0.
  b. The stream inventory is unchanged (count, type, codec, size, pixel format,
     sample rate, channel count) - so no track can be silently dropped.
  c. Decoded output is bit-identical: raw decoded frames (and decoded audio) are
     MD5-hashed for original and result and must match. A wrong unit type - for
     example filter_units reading a MPEG-2 slice row as an SEI - changes pixels
     and is caught here. -NoVerify skips gates b and c; not recommended.

Stream copy only (no re-encode). One temp file per video on the same volume,
then renamed over the original (NTFS rename = no copy). Stream selection is
explicit (-map 0) because ffmpeg's default selection drops every track but the
"best" of each type: measured, a 5-stream MKV (2 audio, 1 video, 1 subtitle,
1 attachment) came back with 3 streams.

Functional metadata is preserved, because it is not identifying and removing it
changes playback behaviour: per-stream language, and attachment filename and
mimetype (the Matroska muxer refuses to write an attachment with no mimetype).

The replacement file mimics the original's filesystem metadata: creation time,
last write time, last access time, and the Archive/Hidden/ReadOnly/System/
NotContentIndexed attributes are captured before ffmpeg reads the file and
applied to the temp before the rename. Not copied: Compressed/Encrypted flags,
alternate data streams, extended attributes, and the security descriptor (the
temp inherits the folder's ACL, which the original usually already shares).
Note: the overwrite is done with Move-Item -Force (Rename-Item -Force cannot
replace an existing file); Move-Item leaves the Archive bit set on overwrite, so
the attribute mask is re-applied to the final file.

-DryRun lists what would be stripped (container tags, chapters, in-band units
found, and what is already clean) without touching any file.
-Audit reports the same inventory for every file and changes nothing.
#>

<#
.SYNOPSIS
Strips container and in-band producer metadata from every video file in the
current folder, using stream copy only and a bit-exact decode check per file.

.DESCRIPTION
Two layers are handled: container metadata (global tags, per-stream tags,
chapters) and the in-band user-data units inside the compressed video
bitstream (H.264 SEI type 6; MPEG-1/2 user_data). See README.md for the
measurements behind each rule, including what cannot be removed.

.PARAMETER DryRun
Report what would be stripped; change nothing.

.PARAMETER Audit
Print each file's metadata inventory - container tags, chapters, in-band units,
and any codec limitation that applies; change nothing.

.PARAMETER NoVerify
Skip the stream-inventory and decoded-bit-exactness gates. Not recommended.

.PARAMETER Help
Show the usage summary and exit without touching any file.

.EXAMPLE
strip-video-meta -DryRun
#>
param([switch]$DryRun, [switch]$Audit, [switch]$NoVerify,
      [Alias('h')] [switch]$Help)
$ErrorActionPreference = 'Stop'

# Help must be handled before any file is listed: PowerShell otherwise accepts
# --help / -? as the built-in -Help common parameter and lets the script run,
# which would strip a whole folder in response to someone asking for help.
if ($Help) {
  @(
    'strip-video-meta - strip container + in-band producer metadata from every',
    'video file in the CURRENT folder (no recursion). Stream copy, no re-encode.',
    '',
    '  strip-video-meta             strip every file here, verifying each one',
    '  strip-video-meta -DryRun     report what would be stripped; change nothing',
    "  strip-video-meta -Audit      print each file's metadata inventory; change nothing",
    '  strip-video-meta -NoVerify   skip the inventory + decoded-bit-exactness',
    '                               gates (not recommended)',
    '  strip-video-meta -Help       this text',
    '',
    '  Extensions: mp4 mkv avi mov m4v webm ts flv wmv m2ts mpg mpeg 3gp asf vob',
    '  Removed:   global tags, per-stream tags, chapters, H.264 SEI user data,',
    '             MPEG-1/2 user_data.',
    '  Kept:      every track bit-identical, stream language, attachment',
    "             filename/mimetype, colour and HDR signalling, the file's own",
    '             timestamps and NTFS attributes.',
    "  Cannot remove: HEVC SEI in MP4/MOV/MKV (reported); Matroska's own",
    '             encoder=Lavf tag (no version number under +bitexact).',
    '',
    '  Get-Help .\strip-video-meta.ps1 -Full   for the longer description.'
  ) | ForEach-Object { Write-Host $_ }
  exit 0
}

$exts = @('mp4','mkv','avi','mov','m4v','webm','ts','flv','wmv','m2ts','mpg','mpeg','3gp','asf','vob')
$keepAttrs = [System.IO.FileAttributes]::Archive -bor
             [System.IO.FileAttributes]::Hidden -bor
             [System.IO.FileAttributes]::ReadOnly -bor
             [System.IO.FileAttributes]::System -bor
             [System.IO.FileAttributes]::NotContentIndexed

# filter unit types per codec for the units that hold user/producer data.
$inBandTypes = @{ h264 = @(6) }
# MPEG-2 user_data start code 0xB2: filter_units matches the low 5 bits of the
# first byte after a 00 00 01 code, so 0xB2 reads as 18. Slice start codes
# 0x01..0xAF are read the same way, and slice rows 82/114/146 would collide with
# 18; gate (c) catches that, and Count-UnitType reports the codes it saw.
$mpegCodecs = @('mpeg1video','mpeg2video')
# Containers whose MPEG-1/2 video is Annex-B in the file bytes, so a byte scan
# finds the units (MP4/MKV store length-prefixed NALs and cannot be scanned).
$inPlaceExt = @('mpg','mpeg','vob','ts','m2ts')
$esFormat = @{ h264 = 'h264'; hevc = 'hevc' }

function Probe([string]$file) {
  $o = & ffprobe -hide_banner -loglevel error -print_format json -show_format -show_streams -show_chapters $file 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  try { return ($o | ConvertFrom-Json) } catch { return $null }
}

function Get-UnitCount {
  # Count Annex-B units whose filter_units-visible type equals $type. Reads in
  # chunks so a multi-GB stream never lands in memory whole.
  param([string]$Path, [int]$Type, [switch]$Hevc)
  if (-not (Test-Path -LiteralPath $Path)) { return -1 }
  $fs = [System.IO.File]::OpenRead($Path)
  try {
    $buf = New-Object byte[] (16MB)
    $carry = New-Object byte[] 0
    $count = 0
    while (($read = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
      if ($carry.Length) {
        $m = New-Object byte[] ($carry.Length + $read)
        [Array]::Copy($carry, 0, $m, 0, $carry.Length)
        [Array]::Copy($buf, 0, $m, $carry.Length, $read)
        $data = $m
      } else {
        $data = New-Object byte[] $read
        [Array]::Copy($buf, 0, $data, 0, $read)
      }
      for ($i = 0; $i -lt $data.Length - 3; $i++) {
        if ($data[$i] -eq 0 -and $data[$i+1] -eq 0 -and $data[$i+2] -eq 1) {
          $b = $data[$i+3]
          $t = if ($Hevc) { ($b -shr 1) -band 0x3F } else { $b -band 0x1F }
          if ($t -eq $Type) { $count++ }
        }
      }
      # Carry the last 3 bytes only: a match needs 4, so a code straddling the
      # chunk boundary is evaluated once, in the chunk that completes it.
      if ($data.Length -gt 3) {
        $carry = New-Object byte[] 3
        [Array]::Copy($data, $data.Length - 3, $carry, 0, 3)
      } else {
        $carry = $data
      }
    }
    return $count
  } finally { $fs.Dispose() }
}

function Dump-Es([string]$Src, [string]$Tmp, [string]$Fmt) {
  & ffmpeg -hide_banner -loglevel error -y -i $Src -map 0:v:0 -c copy -f $Fmt $Tmp 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Get-DecodedHash([string]$File, [string]$Map) {
  # Hash what the file actually decodes to (raw frames, or PCM), not what it
  # contains: this is the gate that proves removal changed no picture.
  $o = & ffmpeg -hide_banner -loglevel error -i $File -map $Map -f md5 - 2>$null
  if ($LASTEXITCODE -ne 0) { return $null }
  $h = ('' + ($o -join '')) -replace '(?s).*md5=', ''
  if ($h -notmatch '^[0-9a-f]{32}$') { return $null }
  return $h
}

function Get-Inventory([string]$File) {
  $p = Probe $File
  if (-not $p) { return $null }
  (@($p.streams | ForEach-Object {
    '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f $_.codec_type, $_.codec_name, $_.width, $_.height,
      $_.pix_fmt, $_.sample_rate, $_.channels, $_.field_order
  }) -join ' ')
}

function Get-Removable([object]$Probe, [string]$ext) {
  # Count what this tool can actually remove: container tags outside the
  # inherent brand fields, plus chapters. Keys the muxer regenerates on every
  # write must not be counted, or a clean file is rewritten on every run:
  # handler_name and DURATION come back from the muxer, language is preserved
  # on purpose, and Matroska always writes its own encoder tag.
  $skip = @('major_brand','minor_version','compatible_brands',
            'handler_name','language','duration','filename','mimetype')
  if (@('mkv','webm') -contains $ext) { $skip += 'encoder' }
  $n = 0
  foreach ($k in @($Probe.format.tags.PSObject.Properties.Name | Where-Object { $_ })) {
    if ($skip -notcontains $k.ToLowerInvariant()) { $n++ }
  }
  foreach ($s in @($Probe.streams)) {
    foreach ($k in @($s.tags.PSObject.Properties.Name | Where-Object { $_ })) {
      if ($skip -notcontains $k.ToLowerInvariant()) { $n++ }
    }
  }
  return @{ tags = $n; chapters = @($Probe.chapters).Count }
}

function Get-InBand([object]$Probe, [string]$Src, [string]$ext) {
  # (unit count, description) for in-band user-data units, or 0 when the codec
  # has no such field or no supported path. Never rewrites anything.
  $out = @{ count = 0; note = ''; removable = $false }
  $vids = @($Probe.streams | Where-Object { $_.codec_type -eq 'video' })
  foreach ($v in $vids) {
    $c = $v.codec_name
    if ($c -eq 'hevc') {
      $tmp = [System.IO.Path]::GetTempFileName()
      if (Dump-Es $Src $tmp 'hevc') {
        $n = (Get-UnitCount -Path $tmp -Type 39 -Hevc) + (Get-UnitCount -Path $tmp -Type 40 -Hevc)
        if ($n -gt 0) {
          $out.count = $n
          $out.note = "$n HEVC SEI units present - filter_units cannot remove them from length-prefixed HEVC in this container, left untouched"
        }
      }
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      continue
    }
    if ($inBandTypes.ContainsKey($c)) {
      $tmp = [System.IO.Path]::GetTempFileName()
      $n = -1
      if (Dump-Es $Src $tmp $esFormat[$c]) { $n = Get-UnitCount -Path $tmp -Type $inBandTypes[$c][0] }
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      if ($n -gt 0) { $out.count += $n; $out.removable = $true }
      continue
    }
    if ($mpegCodecs -contains $c) {
      if ($inPlaceExt -contains $ext) {
        $n = Get-UnitCount -Path $Src -Type 18
        if ($n -gt 0) { $out.count += $n; $out.removable = $true }
      } else {
        $out.note = 'MPEG video in this container is not Annex-B; in-band user_data not scanned'
      }
      continue
    }
    if ($out.note -eq '') { $out.note = "in-band metadata: no producer field defined for $c" }
  }
  return $out
}

$dir = (Get-Location).Path
$ok = 0; $fail = 0; $skip = 0; $would = 0; $warn = 0

foreach ($ext in $exts) {
  foreach ($src in (Get-ChildItem -LiteralPath $dir -File -Force -Filter "*.$ext")) {
    $tmp = Join-Path $dir ($src.BaseName + '.__strip_meta' + $src.Extension)
    # Capture filesystem metadata BEFORE anything reads the file -
    # the read itself refreshes the access time.
    $attrs = [System.IO.File]::GetAttributes($src.FullName)
    $ct = $src.CreationTime; $mt = $src.LastWriteTime; $at = $src.LastAccessTime

    $probe = Probe $src.FullName
    if (-not $probe) {
      $fail++
      Write-Host "FAILED: $($src.Name) (ffprobe could not read it; original untouched)"
      continue
    }
    $rem = Get-Removable $probe $ext
    $band = Get-InBand $probe $src.FullName $ext
    $bandTxt = if ($band.count) { "in-band units: $($band.count)" } else { 'in-band units: 0' }
    if ($Audit) {
      Write-Host ("AUDIT {0}  container tags: {1}  chapters: {2}  {3}" -f $src.Name, $rem.tags, $rem.chapters, $bandTxt)
      if ($band.note) { Write-Host "      note: $($band.note)" }
      continue
    }
    if ($rem.tags -eq 0 -and $rem.chapters -eq 0 -and -not $band.removable) {
      Write-Host "Skipping: $($src.Name) (nothing removable)"
      if ($band.note) { Write-Host "        note: $($band.note)"; $warn++ }
      $skip++
      continue
    }
    if ($DryRun) {
      Write-Host ("Would strip: {0}  container tags: {1}  chapters: {2}  {3}" -f $src.Name, $rem.tags, $rem.chapters, $bandTxt)
      if ($band.note) { Write-Host "        note: $($band.note)" }
      $would++
      continue
    }

    Write-Host ("Stripping: {0}  container tags: {1}  chapters: {2}  {3}" -f $src.Name, $rem.tags, $rem.chapters, $bandTxt)

    # Explicit stream selection: -map 0 keeps every track (default selection
    # drops all but the best of each type). Then wipe the file's tags, the
    # chapters, and the tags of every stream type that is actually present.
    $ff = @('-hide_banner', '-loglevel', 'error', '-y', '-i', $src.FullName, '-map', '0',
            '-map_metadata', '-1', '-map_chapters', '-1')
    $types = @($probe.streams | ForEach-Object { $_.codec_type } | Select-Object -Unique)
    $spec = @{ video = 'v'; audio = 'a'; subtitle = 's'; data = 'd' }
    foreach ($t in $types) {
      if ($spec.ContainsKey($t)) { $ff += @("-map_metadata:s:$($spec[$t])", '-1') }
    }
    # Re-apply the tags that carry function rather than provenance.
    foreach ($s in @($probe.streams)) {
      $i = $s.index
      $lang = $s.tags.language
      if ($lang) { $ff += @("-metadata:s:$i", "language=$lang") }
      if ($s.codec_type -eq 'attachment') {
        foreach ($k in @('filename','mimetype')) {
          $val = $s.tags.$k
          if ($val) { $ff += @("-metadata:s:$i", "$k=$val") }
        }
      }
    }
    # In-band removal, one unit type per codec, per video stream.
    $vi = 0
    foreach ($v in @($probe.streams | Where-Object { $_.codec_type -eq 'video' })) {
      $c = $v.codec_name
      if ($inBandTypes.ContainsKey($c)) {
        $ff += @("-bsf:v:$vi", "filter_units=remove_types=$($inBandTypes[$c][0] -join ',')")
      } elseif ($mpegCodecs -contains $c -and $inPlaceExt -contains $ext) {
        $ff += @("-bsf:v:$vi", 'filter_units=remove_types=18')
      }
      $vi++
    }
    # -fflags +bitexact suppresses the muxer's own "encoder=Lavf..." tag.
    $ff += @('-fflags', '+bitexact', '-c', 'copy', $tmp)

    & ffmpeg @ff
    if ($LASTEXITCODE -ne 0) {
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      $fail++
      Write-Host "FAILED: $($src.Name) (ffmpeg error; original left untouched)"
      continue
    }

    if (-not $NoVerify) {
      $why = $null
      if ((Get-Inventory $src.FullName) -ne (Get-Inventory $tmp)) { $why = 'stream inventory changed' }
      if (-not $why) {
        foreach ($tag in @('v','a')) {
          $n = @($probe.streams | Where-Object { $_.codec_type -eq @{v='video';a='audio'}[$tag] }).Count
          for ($j = 0; $j -lt $n; $j++) {
            $h1 = Get-DecodedHash $src.FullName "0:${tag}:$j"
            $h2 = Get-DecodedHash $tmp "0:${tag}:$j"
            if ($null -eq $h1 -or $h1 -ne $h2) { $why = "decoded $tag stream $j differs"; break }
          }
          if ($why) { break }
        }
      }
      if ($why) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        $fail++
        Write-Host "FAILED: $($src.Name) ($why; original left untouched, nothing written)"
        continue
      }
    }

    try {
      $t = [System.IO.FileInfo]::new($tmp)
      $t.CreationTime = $ct
      $t.LastWriteTime = $mt
      $t.LastAccessTime = $at
      $t.Attributes = [System.IO.FileAttributes]($attrs -band $keepAttrs)
      if ($src.IsReadOnly) { $src.IsReadOnly = $false }
      Move-Item -LiteralPath $tmp -Destination $src.FullName -Force
      # Move-Item -Force leaves the Archive bit set when it overwrites;
      # re-apply the original's mask so the result matches exactly.
      [System.IO.File]::SetAttributes($src.FullName, [System.IO.FileAttributes]($attrs -band $keepAttrs))
      if ($band.note) { Write-Host "        note: $($band.note)"; $warn++ }
      $ok++
    }
    catch {
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      $fail++
      Write-Host "FAILED: $($src.Name) (rename error; original left untouched)"
    }
  }
}

if ($Audit) {
  $n = @(Get-ChildItem -LiteralPath $dir -File -Force | Where-Object { $exts -contains $_.Extension.TrimStart('.') }).Count
  Write-Host "Audit: $n files reported, nothing changed."
} elseif ($DryRun) {
  Write-Host "Dry run: $would would be stripped, $skip have nothing removable."
} else {
  Write-Host "Done: $ok stripped, $skip skipped, $fail failed, $warn reported a limitation."
}
