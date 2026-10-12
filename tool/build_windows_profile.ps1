param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('stable', 'dev')]
    [string]$Profile,

    [Parameter(Mandatory = $true)]
    [string]$Target
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$distRoot = [System.IO.Path]::GetFullPath((Join-Path $repoRoot 'dist'))
$distTarget = [System.IO.Path]::GetFullPath((Join-Path $distRoot $Profile))
$expectedParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $distTarget))
if ($expectedParent -ne $distRoot) {
    throw "Refusing to package outside the repository dist directory: $distTarget"
}

Push-Location $repoRoot
try {
    flutter build windows --release -t $Target
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter build failed for profile $Profile."
    }

    $releaseBundle = Join-Path $repoRoot 'build\windows\x64\runner\Release'
    if (-not (Test-Path -LiteralPath $releaseBundle -PathType Container)) {
        throw "Windows Release bundle was not found at $releaseBundle"
    }

    if (Test-Path -LiteralPath $distTarget) {
        Remove-Item -LiteralPath $distTarget -Recurse -Force
    }
    New-Item -ItemType Directory -Path $distTarget -Force | Out-Null
    Copy-Item -Path (Join-Path $releaseBundle '*') -Destination $distTarget -Recurse -Force

    $branch = (git branch --show-current).Trim()
    $commit = (git rev-parse HEAD).Trim()
    $builtAt = [DateTimeOffset]::Now.ToString('o')
    $profileLabel = $Profile.ToUpperInvariant()
    $pubspecContent = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'pubspec.yaml')
    $versionMatch = [regex]::Match($pubspecContent, '(?m)^version:\s*([^\s#]+)')
    if (-not $versionMatch.Success) {
        throw 'Unable to read the product version from pubspec.yaml.'
    }
    $productVersion = $versionMatch.Groups[1].Value
    $channel = if ($Profile -eq 'stable') { 'Personal Alpha' } else { 'Development' }
    $buildInfo = @(
        'Product: Stash'
        "Channel: $channel"
        "Version: $productVersion"
        "Profile: $profileLabel"
        "Entrypoint: $Target"
        "Branch: $branch"
        "Commit: $commit"
        "Built at: $builtAt"
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText(
        (Join-Path $distTarget 'BUILD_INFO.txt'),
        $buildInfo + [Environment]::NewLine
    )

    Write-Host "Packaged complete $profileLabel bundle at $distTarget"
}
finally {
    Pop-Location
}
