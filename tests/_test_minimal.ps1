function Outer {
    Inner
}
function Inner {
    Write-Host "Inner works!"
}
Outer
