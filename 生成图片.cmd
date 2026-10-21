@echo off
rem Wrapper for the local .ps1 (this machine blocks .ps1 by execution policy).
setlocal
if "%~1"=="" (
  echo.
  echo  Usage: "%~nx0" "a cat in the sun, watercolor" [-Ratio 1:1] [-Out cat.png]
  echo  Ratios: 1:1  4:3  3:4  3:2  2:3  16:9  9:16
  echo.
  pause
  exit /b 1
)
for %%F in ("%~dp0*.ps1") do set "PSFILE=%%~fF"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PSFILE%" %*
exit /b %errorlevel%
