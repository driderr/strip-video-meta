@echo off
rem strip-video-meta.cmd - local shim: runs the project's
rem strip-video-meta.ps1 on the videos in the current folder.
rem (A copy kept in any folder on your PATH works as a shim: it calls
rem this project's .ps1 by absolute path.)
rem
rem Help words are intercepted here on purpose. PowerShell takes --help,
rem -help and -? as its built-in -Help common parameter and lets the script
rem run, so without this block asking for help would strip the whole folder.
if "%~1"=="" goto run
if /i "%~1"=="-h" goto help
if /i "%~1"=="-?" goto help
if /i "%~1"=="/?" goto help
if /i "%~1"=="-help" goto help
if /i "%~1"=="--help" goto help
if /i "%~1"=="/help" goto help
goto run

:help
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0strip-video-meta.ps1" -Help
exit /b %ERRORLEVEL%

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0strip-video-meta.ps1" %*
