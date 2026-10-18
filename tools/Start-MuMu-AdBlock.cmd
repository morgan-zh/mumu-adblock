@echo off
setlocal
set "SCRIPT=%~dp0MuMu-AdBlock.ps1"

if not exist "%SCRIPT%" (
  echo [ERROR] MuMu-AdBlock.ps1 not found next to this launcher.
  echo Keep both files in the same folder.
  pause
  exit /b 1
)

:menu
cls
echo ============================================================
echo   MuMu Player Ad Cleaner (portable)
echo ============================================================
echo   1. Apply    - remove ads (admin, UAC prompt may appear)
echo   2. Verify   - read-only status check
echo   3. Restore  - undo every change
echo   4. Dry run  - preview, writes nothing
echo   5. Detect   - show detected install/port/state
echo   0. Exit
echo ============================================================
set "choice="
set /p "choice=Select [0-5]: "

if "%choice%"=="1" goto apply
if "%choice%"=="2" goto verify
if "%choice%"=="3" goto restore
if "%choice%"=="4" goto dryrun
if "%choice%"=="5" goto detect
if "%choice%"=="0" exit /b 0
goto menu

:apply
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Action Apply
set "RC=%ERRORLEVEL%"
goto end

:verify
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Action Verify
set "RC=%ERRORLEVEL%"
goto end

:restore
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Action Restore
set "RC=%ERRORLEVEL%"
goto end

:dryrun
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Action Apply -DryRun
set "RC=%ERRORLEVEL%"
goto end

:detect
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Action Detect
set "RC=%ERRORLEVEL%"
goto end

:end
echo.
echo Done (exit code %RC%). Logs: %LOCALAPPDATA%\MuMu-AdBlock\logs
pause
exit /b %RC%
