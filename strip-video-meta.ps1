<#
strip-video-meta.ps1 - strip container metadata (global tags + chapters)
from every video file in the current folder. Structural ftyp brand
tags are inherent to the format and cannot be removed.

Stream copy only (no re-encode). One temp file per video on the same
volume, then renamed over the original (NTFS rename = no copy) - no
redundant files left behind. On failure the original is untouched.
Files holding nothing removable (only the inherent ftyp brand tags,
no chapters) are detected with a fast ffprobe pre-check and skipped
without being rewritten.
-DryRun lists what would be stripped (and what is already clean)
without touching any file.

The replacement file mimics the original's filesystem metadata:
creation time, last write time, last access time, and the
Archive/Hidden/ReadOnly/System/NotContentIndexed attributes are
captured before ffmpeg reads the file and applied to the temp before
the rename. Not copied: Compressed/Encrypted flags, alternate data
streams, extended attributes, and the security descriptor (the temp
inherits the folder's ACL, which the original usually already shares).
Note: the overwrite is done with Move-Item -Force (Rename-Item -Force
cannot replace an existing file); Move-Item leaves the Archive bit set
on overwrite, so the attribute mask is re-applied to the final file.
#>

param([switch]$DryRun)
$ErrorActionPreference = 'Stop'

$exts = @('mp4','mkv','avi','mov','m4v','webm','ts','flv','wmv','m2ts','mpg','mpeg','3gp','asf','vob')
$keepAttrs = [System.IO.FileAttributes]::Archive -bor
             [System.IO.FileAttributes]::Hidden -bor
             [System.IO.FileAttributes]::ReadOnly -bor
             [System.IO.FileAttributes]::System -bor
             [System.IO.FileAttributes]::NotContentIndexed

$dir = (Get-Location).Path
$ok = 0
$fail = 0
$skip = 0
$would = 0

foreach ($ext in $exts) {
  foreach ($src in (Get-ChildItem -LiteralPath $dir -File -Force -Filter "*.$ext")) {
    $tmp = Join-Path $dir ($src.BaseName + '.__strip_meta' + $src.Extension)
    # Capture filesystem metadata BEFORE anything reads the file -
    # the read itself refreshes the access time.
    $attrs = [System.IO.File]::GetAttributes($src.FullName)
    $ct = $src.CreationTime
    $mt = $src.LastWriteTime
    $at = $src.LastAccessTime

    # Pre-check: if the file holds nothing removable (only the
    # inherent ftyp brand tags, no chapters), skip it - a full
    # rewrite would be pure waste. If ffprobe itself fails, fall
    # through and let the real attempt decide.
    $pre = & ffprobe -hide_banner -loglevel error -show_entries format_tags:chapters -of default=noprint_wrappers=1 $src.FullName 2>$null
    if ($LASTEXITCODE -eq 0) {
      $removable = @($pre | Where-Object { $_ -like 'TAG:*' -and $_ -notlike 'TAG:major_brand=*' -and $_ -notlike 'TAG:minor_version=*' -and $_ -notlike 'TAG:compatible_brands=*' })
      $hasChapters = @($pre | Where-Object { $_ -like 'CHAPTER#*' }).Count -gt 0
      if ($removable.Count -eq 0 -and -not $hasChapters) {
        Write-Host "Skipping: $($src.Name) (no removable metadata)"
        $skip++
        continue
      }
    }

    if ($DryRun) {
      Write-Host "Would strip: $($src.Name)"
      $would++
      continue
    }

    Write-Host "Stripping: $($src.Name)"

    # -fflags +bitexact suppresses the muxer's own "encoder=Lavf..." tag
    & ffmpeg -hide_banner -loglevel error -y -i $src.FullName -map_metadata -1 -map_chapters -1 -fflags +bitexact -c copy $tmp
    if ($LASTEXITCODE -ne 0) {
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      $fail++
      Write-Host "FAILED: $($src.Name) (original left untouched)"
      continue
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
      $ok++
    }
    catch {
      Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
      $fail++
      Write-Host "FAILED: $($src.Name) (original left untouched)"
    }
  }
}

if ($DryRun) {
  Write-Host "Dry run: $would would be stripped, $skip have no removable metadata."
} else {
  Write-Host "Done: $ok stripped, $skip skipped, $fail failed."
}
