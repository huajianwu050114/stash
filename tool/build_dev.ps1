$ErrorActionPreference = 'Stop'

& "$PSScriptRoot\build_windows_profile.ps1" `
    -Profile dev `
    -Target lib/main_dev.dart
