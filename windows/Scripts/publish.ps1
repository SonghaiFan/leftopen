# Builds release artifacts for LeftOpen on Windows.
# Usage: powershell -File windows\Scripts\publish.ps1 [-OutputDir windows\dist] [-SelfContained] [-Shared]
#
# Default: framework-dependent single-file executables (~1.5 MB each) — small and
# fast to start, but require the .NET 8 runtime (SDK or Desktop Runtime).
# -SelfContained: standalone single-file executables that run on any Windows 10+ box
# without a runtime, at the cost of size (WinForms cannot be trimmed).
# -Shared: the release layout — both executables sharing one self-contained runtime
# folder (~67 MB zipped instead of ~91 MB for two single-file exes), then zipped.
# Unzip and run; no .NET installation needed. This is what CI packages.

param(
    # Relative paths resolve against the repository root, not the current directory.
    [string]$OutputDir = "windows\dist",
    [switch]$SelfContained,
    [switch]$Shared
)

$ErrorActionPreference = "Stop"
# This script lives in <repo>\windows\Scripts, so the repo root is two levels up.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $repoRoot

$common = @("-c", "Release", "-r", "win-x64")
if ($SelfContained -or $Shared) {
    $common += "--self-contained", "true"
}
else {
    $common += "--self-contained", "false", "-p:PublishSingleFile=true"
}

$projects = @(
    "windows\src\LeftOpen.Cli\LeftOpen.Cli.csproj",
    "windows\src\LeftOpen.Tray\LeftOpen.Tray.csproj"
)

if ($Shared) {
    $folder = Join-Path $OutputDir "LeftOpen-windows-x64"
    Write-Host "==> Publishing shared-runtime folder to $folder..." -ForegroundColor Cyan
    foreach ($project in $projects) {
        dotnet publish $project @common -o $folder
        if ($LASTEXITCODE -ne 0) { throw "publish failed for $project" }
    }

    $zip = Join-Path $OutputDir "LeftOpen-windows-x64.zip"
    Write-Host "==> Zipping $zip..." -ForegroundColor Cyan
    Compress-Archive -Path $folder -DestinationPath $zip -Force

    Write-Host ""
    Write-Host "Done. Self-contained package in ${OutputDir}:" -ForegroundColor Green
    "{0,-26} {1,10:N1} MB" -f (Split-Path -Leaf $zip), ((Get-Item $zip).Length / 1MB)
    return
}

foreach ($project in $projects) {
    $name = Split-Path -Leaf (Split-Path -Parent $project)
    Write-Host "==> Publishing $name..." -ForegroundColor Cyan
    dotnet publish $project @common -o $OutputDir
    if ($LASTEXITCODE -ne 0) { throw "publish failed for $project" }
}

Write-Host ""
Write-Host "Done. Artifacts in ${OutputDir}:" -ForegroundColor Green
Get-ChildItem $OutputDir -Filter *.exe | ForEach-Object {
    "{0,-20} {1,10:N0} KB" -f $_.Name, ($_.Length / 1KB)
}
