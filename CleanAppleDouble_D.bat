@echo off
rem Double-click: permanently delete Mac "._" files on drive D: only. No confirmation.
call "%~dp0CleanAppleDouble.bat" -ScanDrives D
