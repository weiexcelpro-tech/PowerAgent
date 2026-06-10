@echo off
:: Power - PowerAgent launcher
:: Usage: power [args...]
::   power                  Interactive mode
::   power --install        Install PowerAgent
::   power --run            Start daemon
::   power --debug          Debug mode
::   power --help           Show all options
::   power --test           Run test suite

setlocal

:: Resolve script directory (handles being called from any working directory)
set "SCRIPT_DIR=%~dp0"

:: Check for --test flag first
if "%~1"=="--test" (
    echo [Power] Running test suite...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%tests\run_tests.ps1"
    exit /b %ERRORLEVEL%
)

:: Run PowerAgent with all forwarded arguments
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%PowerAgent.ps1" %*

endlocal
