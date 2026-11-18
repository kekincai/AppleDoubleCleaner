@echo off
setlocal
title Clean AppleDouble ._ files

rem Double-click to scan every connected exFAT/FAT drive and permanently delete
rem Mac "._" metadata files. No confirmation prompt.
rem Safety checks stay on: only files whose header is AppleDouble are deleted,
rem NTFS drives (C:) are never touched. Logs go to the "logs" folder next to this file.
rem All drives are processed at the same time, each in its own window; this window
rem waits and prints a combined summary. Add -Sequential to do one drive at a time.
rem Extra arguments replace the default "-AllExFat", e.g.:  CleanAppleDouble.bat -ScanDrives E,F

set "ARGS=%*"
if "%ARGS%"=="" set "ARGS=-AllExFat"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Clean-AppleDouble.ps1" %ARGS% -Execute -Yes -LogDir "%~dp0logs"

echo.
pause
