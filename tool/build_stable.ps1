$ErrorActionPreference = 'Stop'

& "$PSScriptRoot\build_windows_profile.ps1" `
    -Profile stable `
    -Target lib/main.dart
