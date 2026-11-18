@echo off
rem Double-click: permanently delete Mac "._" files on drive G: only. No confirmation.
call "%~dp0CleanAppleDouble.bat" -ScanDrives G
