@echo off
rem strip-video-meta.cmd - local shim: runs the project's
rem strip-video-meta.ps1 on the videos in the current folder.
rem (A copy kept in any folder on your PATH works as a shim: it calls
rem this project's .ps1 by absolute path.)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0strip-video-meta.ps1" %*
