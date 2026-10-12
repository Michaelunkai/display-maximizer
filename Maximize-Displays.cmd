@echo off
rem display-maximizer launcher - double-click friendly wrapper.
rem Default verb: apply (maximize every display, then verify).
rem Pass -VerifyOnly / -ListModes / -Json through unchanged.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0display-maximizer.ps1" %*
