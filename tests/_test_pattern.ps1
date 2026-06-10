# Test: Can a function defined early in a script call a function defined later?
# Simulating the exact pattern of PowerAgent.ps1

# Script-level variables (like PowerAgent line 7-18)
$script:PA_ROOT = $PSScriptRoot
$script:PA_MODE = "oneshot"

# Function defined early (like Start-PowerAgent at line 308)
function Start-Main {
    Write-Host "Start-Main called"
    Write-Host "Calling Helper-A..."
    Helper-A
    Write-Host "Calling Helper-B..."
    Helper-B
}

# Stub functions (like PowerAgent line 459-462)
function Stub-One { Write-Host "Stub-One" }

# Entry guard (like PowerAgent line 469-471)
if ($MyInvocation.InvocationName -ne '.') {
    Start-Main @args
}

# Functions defined AFTER entry guard (like inline modules at line 474+)
function Helper-A {
    Write-Host "Helper-A works!"
}

function Helper-B {
    Write-Host "Helper-B works!"
}
