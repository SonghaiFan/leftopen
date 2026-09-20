# Builds release artifacts for LeftOpen on Windows.
# Usage: powershell -File Scripts\publish.ps1 [-OutputDir dist] [-SelfContained]
#
# Default: framework-dependent single-file executables (~1.5 MB each) — small and
# fast to start, but require the .NET 8 runtime (SDK or Desktop Runtime).
# -SelfContained: standalone executables that run on any Windows 10+ box without
# a runtime, at the cost of size (WinForms cannot be trimmed).

param(
    [string]$OutputDir = "dist",
    [switch]$SelfContained
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$common = @("-c", "Release", "-r", "win-x64", "-p:PublishSingleFile=true")
if ($SelfContained) {
    $common += "--self-contained", "true", "-p:IncludeNativeLibrariesForSelfExtract=true"
}
else {
    $common += "--self-contained", "false"
}

Write-Host "==> Publishing CLI (leftopen.exe)..." -ForegroundColor Cyan
dotnet publish "src\LeftOpen.Cli\LeftOpen.Cli.csproj" @common -o $OutputDir
if ($LASTEXITCODE -ne 0) { throw "CLI publish failed." }

Write-Host "==> Publishing tray app (LeftOpenApp.exe)..." -ForegroundColor Cyan
dotnet publish "src\LeftOpen.Tray\LeftOpen.Tray.csproj" @common -o $OutputDir
if ($LASTEXITCODE -ne 0) { throw "Tray publish failed." }

Write-Host ""
Write-Host "Done. Artifacts in ${OutputDir}:" -ForegroundColor Green
Get-ChildItem $OutputDir -Filter *.exe | ForEach-Object {
    "{0,-20} {1,10:N0} KB" -f $_.Name, ($_.Length / 1KB)
}
