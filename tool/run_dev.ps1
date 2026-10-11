$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    flutter run -d windows -t lib/main_dev.dart
}
finally {
    Pop-Location
}
