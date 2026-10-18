param(
  # Leave web out: an old build/web would otherwise be filed under this
  # version.
  [switch]$SkipWeb
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $repo 'dist'
$latest = Join-Path $dist 'latest'
$releases = Join-Path $dist 'releases'

function Get-AppVersion {
  $pubspec = Join-Path $repo 'pubspec.yaml'
  $line = Get-Content -Path $pubspec | Where-Object { $_ -match '^version:\s*(.+)$' } | Select-Object -First 1
  if ($line -match '^version:\s*(.+)$') {
    return $Matches[1].Trim().Replace('+', '_')
  }
  return 'unknown'
}

function Assert-InRepo([string]$Path) {
  $resolvedRepo = [System.IO.Path]::GetFullPath($repo)
  $full = [System.IO.Path]::GetFullPath($Path)
  if (-not $full.StartsWith($resolvedRepo, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to write outside repository: $full"
  }
}

function Reset-Directory([string]$Path) {
  Assert-InRepo $Path
  if (Test-Path $Path) {
    Remove-Item -LiteralPath $Path -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Copy-IfExists([string]$Source, [string]$DestinationDir, [string]$Name = $null) {
  if (-not (Test-Path $Source)) {
    Write-Host "Missing: $Source"
    return
  }
  New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null
  $destination = if ($Name) { Join-Path $DestinationDir $Name } else { Join-Path $DestinationDir (Split-Path -Leaf $Source) }
  Copy-Item -LiteralPath $Source -Destination $destination -Force
  Write-Host "Copied: $destination"
}

function Copy-DirectoryIfExists([string]$Source, [string]$Destination) {
  if (-not (Test-Path $Source)) {
    Write-Host "Missing: $Source"
    return
  }
  if (Test-Path $Destination) {
    Remove-Item -LiteralPath $Destination -Recurse -Force
  }
  Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
  Write-Host "Copied: $Destination"
}

$version = Get-AppVersion
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$releaseName = "v$version-$stamp"
$releaseDir = Join-Path $releases $releaseName

Reset-Directory $latest
Reset-Directory $releaseDir

$targets = @($latest, $releaseDir)

foreach ($target in $targets) {
  $androidDir = Join-Path $target 'android'
  $windowsDir = Join-Path $target 'windows'
  $webDir = Join-Path $target 'web'

  Copy-IfExists (Join-Path $repo 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk') $androidDir 'Influencor-arm64-v8a-release.apk'
  Copy-IfExists (Join-Path $repo 'build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk') $androidDir 'Influencor-armeabi-v7a-release.apk'
  Copy-IfExists (Join-Path $repo 'build/app/outputs/flutter-apk/app-x86_64-release.apk') $androidDir 'Influencor-x86_64-release.apk'
  Copy-IfExists (Join-Path $repo 'build/app/outputs/flutter-apk/app-release.apk') $androidDir 'Influencor-universal-release.apk'
  Copy-IfExists (Join-Path $repo 'build/app/outputs/bundle/release/app-release.aab') $androidDir 'Influencor-release.aab'

  Copy-IfExists (Join-Path $repo 'build/installer/InfluencorSetup.exe') $windowsDir 'InfluencorSetup.exe'
  Copy-IfExists (Join-Path $repo 'build/msix/Influencor.msix') $windowsDir 'Influencor.msix'
  Copy-IfExists (Join-Path $repo 'build/windows/x64/runner/Influencor.exe') $windowsDir 'Influencor-portable.exe'
  Copy-IfExists (Join-Path $repo 'build/windows/x64/runner/Release/influencor.exe') $windowsDir 'influencor.exe'
  # The whole Release folder (exe + DLLs + data): the bare exe cannot run alone.
  Copy-IfExists (Join-Path $repo 'build/windows/x64/runner/influencor-windows-release.zip') $windowsDir 'Influencor-windows-x64.zip'

  if (-not $SkipWeb) {
    Copy-DirectoryIfExists (Join-Path $repo 'build/web') $webDir
  }
}

Write-Host ''
Write-Host "Release artifacts collected:"
Write-Host "  Latest:   $latest"
Write-Host "  Release:  $releaseDir"
