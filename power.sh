#!/usr/bin/env bash
# Power - PowerAgent launcher (Git Bash / WSL)
# Usage: power [args...]
#   power                  Interactive mode
#   power --install        Install PowerAgent
#   power --run            Start daemon
#   power --debug          Debug mode
#   power --help           Show all options
#   power --test           Run test suite

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Convert POSIX path to Windows path for PowerShell
WIN_SCRIPT_DIR="$(cygpath -w "$SCRIPT_DIR" 2>/dev/null || echo "$SCRIPT_DIR" | sed 's|/c/|C:\\|g; s|/|\\|g')"

if [ "$1" = "--test" ]; then
    echo "[Power] Running test suite..."
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${WIN_SCRIPT_DIR}\\tests\\run_tests.ps1"
    exit $?
fi

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${WIN_SCRIPT_DIR}\\PowerAgent.ps1" "$@"
