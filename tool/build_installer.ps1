param(
    [switch]$SkipFlutterBuild
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$stableBundle = Join-Path $repoRoot 'dist\stable'
$installerOutput = Join-Path $repoRoot 'dist\installer'
$installerName = 'StashSetup-0.6.0-alpha.exe'
$installerPath = Join-Path $installerOutput $installerName
$installerBuildInfo = Join-Path $installerOutput 'BUILD_INFO.txt'
$expectedVersion = '0.6.0+2'

function Get-InnoSetupCompiler {
    if ($env:ISCC_PATH) {
        if (Test-Path -LiteralPath $env:ISCC_PATH -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($env:ISCC_PATH)
        }
        throw "ISCC_PATH does not point to a file: $($env:ISCC_PATH)"
    }

    $command = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @()
    if (${env:ProgramFiles(x86)}) {
        $candidates += Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
    }
    if ($env:ProgramFiles) {
        $candidates += Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'
    }
    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    return $null
}

Push-Location $repoRoot
try {
    $pubspecContent = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'pubspec.yaml')
    $versionMatch = [regex]::Match($pubspecContent, '(?m)^version:\s*([^\s#]+)')
    if (-not $versionMatch.Success) {
        throw 'Unable to read the product version from pubspec.yaml.'
    }

    $productVersion = $versionMatch.Groups[1].Value
    if ($productVersion -ne $expectedVersion) {
        throw "Installer release expects pubspec version $expectedVersion, but found $productVersion."
    }

    if (-not $SkipFlutterBuild) {
        & (Join-Path $PSScriptRoot 'build_stable.ps1')
        if ($LASTEXITCODE -ne 0) {
            throw 'Stable Windows build failed.'
        }
    }

    if (-not (Test-Path -LiteralPath $stableBundle -PathType Container)) {
        throw "Stable bundle was not found at $stableBundle. Run without -SkipFlutterBuild first."
    }

    $requiredBundleItems = @(
        'stash.exe'
        'flutter_windows.dll'
        'data\app.so'
        'data\flutter_assets'
        'sqlite3.dll'
        'hotkey_manager_windows_plugin.dll'
        'window_manager_plugin.dll'
        'BUILD_INFO.txt'
    )
    foreach ($relativePath in $requiredBundleItems) {
        $requiredPath = Join-Path $stableBundle $relativePath
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Stable bundle is incomplete; missing $relativePath"
        }
    }

    $stableBuildInfo = Get-Content -Raw -LiteralPath (Join-Path $stableBundle 'BUILD_INFO.txt')
    if ($stableBuildInfo -notmatch '(?m)^Profile:\s+STABLE\s*$') {
        throw 'Stable bundle BUILD_INFO.txt does not identify the STABLE profile.'
    }
    if ($stableBuildInfo -notmatch '(?m)^Entrypoint:\s+lib/main\.dart\s*$') {
        throw 'Stable bundle BUILD_INFO.txt does not identify lib/main.dart as its entrypoint.'
    }
    if ($stableBuildInfo -match 'main_dev\.dart') {
        throw 'Refusing to package a bundle whose BUILD_INFO.txt references the Dev entrypoint.'
    }

    $devInstallers = @(
        Get-ChildItem -LiteralPath $installerOutput -Filter '*Dev*Setup*.exe' -File -ErrorAction SilentlyContinue
    )
    if ($devInstallers.Count -gt 0) {
        throw "Refusing to continue while a Dev installer exists: $($devInstallers.FullName -join ', ')"
    }

    $isccPath = Get-InnoSetupCompiler
    if (-not $isccPath) {
        Write-Error @'
Inno Setup 6 is required to build the Stash installer.
Install it with "winget install --id JRSoftware.InnoSetup --exact" or download it from https://jrsoftware.org/isdl.php, then rerun this script.
'@
    }

    New-Item -ItemType Directory -Path $installerOutput -Force | Out-Null
    foreach ($oldArtifact in @($installerPath, $installerBuildInfo)) {
        if (Test-Path -LiteralPath $oldArtifact -PathType Leaf) {
            Remove-Item -LiteralPath $oldArtifact -Force
        }
    }

    & $isccPath (Join-Path $repoRoot 'installer\stash.iss')
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
    }

    if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
        throw "Inno Setup completed but the expected installer was not found at $installerPath"
    }

    $installerHash = (Get-FileHash -LiteralPath $installerPath -Algorithm SHA256).Hash
    $branch = (git branch --show-current).Trim()
    $commit = (git rev-parse HEAD).Trim()
    $builtAt = [DateTimeOffset]::Now.ToString('o')
    $metadata = @(
        'Product: Stash'
        'Channel: Personal Alpha'
        'Version: 0.6.0'
        'Profile: STABLE'
        "Git Branch: $branch"
        "Git Commit: $commit"
        "Built At: $builtAt"
        "Installer: $installerName"
        "Installer SHA256: $installerHash"
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText(
        $installerBuildInfo,
        $metadata + [Environment]::NewLine
    )

    Write-Host "Installer: $installerPath"
    Write-Host "SHA256:   $installerHash"
    Write-Host "Build info: $installerBuildInfo"
}
finally {
    Pop-Location
}
