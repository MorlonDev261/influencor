param(
  # Android + Windows only (no web build).
  [switch]$SkipWeb,
  # Do not publish the new APK/EXE to the influencor-web site.
  [switch]$SkipWebsite
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$jbr = Join-Path $env:USERPROFILE '.jdks\jbr-21.0.11'
$singleExeBuilder = Join-Path $PSScriptRoot 'make_windows_single_exe.ps1'
$collector = Join-Path $PSScriptRoot 'collect_release_artifacts.ps1'

if (Test-Path $jbr) {
  $env:JAVA_HOME = $jbr
  $env:Path = "$env:JAVA_HOME\bin;$env:Path"
}

# Degany's model (.env, see .env.example), when the file exists.
$defines = @()
if (Test-Path (Join-Path $repo '.env')) { $defines = @('--dart-define-from-file=.env') }

Push-Location $repo
try {
  flutter build windows --release @defines
  if ($LASTEXITCODE -ne 0) { throw "Windows build failed" }

  $releaseDir = Join-Path $repo 'build/windows/x64/runner/Release'
  $payload = Join-Path $repo 'build/windows/x64/runner/influencor-windows-release.zip'
  if (Test-Path $payload) {
    Remove-Item -LiteralPath $payload -Force
  }
  Compress-Archive -Path (Join-Path $releaseDir '*') -DestinationPath $payload -Force
  powershell -NoProfile -ExecutionPolicy Bypass -File $singleExeBuilder

  # iscc on PATH, or the per-user / machine-wide Inno Setup 6 install.
  $iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source
  if (-not $iscc) {
    $iscc = @(
      (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
      (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
      (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  }
  if ($iscc) {
    & $iscc installer/influencor.iss
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed ($LASTEXITCODE)" }
  } else {
    Write-Host 'Inno Setup compiler (iscc) not found; skipping Windows installer.'
  }

  # Microsoft Store package (build/msix/Influencor.msix), from the Release
  # build above. Needs the Partner Center identity in pubspec's msix_config.
  if (Select-String -Path pubspec.yaml -Pattern '^\s+identity_name:\s*[^\s#]' -Quiet) {
    dart run msix:create
    if ($LASTEXITCODE -ne 0) { throw "MSIX build failed ($LASTEXITCODE)" }
  } else {
    Write-Host 'msix_config identity not set in pubspec.yaml; skipping Microsoft Store package.'
  }

  # Android: one APK per ABI, a universal APK, and the Play Store bundle.
  flutter build apk --release --split-per-abi @defines
  if ($LASTEXITCODE -ne 0) { throw "APK (split) build failed" }
  flutter build apk --release @defines
  if ($LASTEXITCODE -ne 0) { throw "APK (universal) build failed" }
  flutter build appbundle --release @defines
  if ($LASTEXITCODE -ne 0) { throw "AAB build failed" }

  if (-not $SkipWeb) {
    flutter build web --release --no-wasm-dry-run
  }

  if ($SkipWeb) {
    powershell -NoProfile -ExecutionPolicy Bypass -File $collector -SkipWeb
  } else {
    powershell -NoProfile -ExecutionPolicy Bypass -File $collector
  }

  # Website (influencor-web repo, cloned next to this one): copy the new APK/EXE,
  # commit and push; the server picks the commit up within 5 minutes.
  if (-not $SkipWebsite) {
    $website = Join-Path (Split-Path -Parent $repo) 'influencor-web'
    if (Test-Path (Join-Path $website 'package.json')) {
      Push-Location $website
      try {
        bun run publish-release
        if ($LASTEXITCODE -ne 0) { throw "Website publish failed ($LASTEXITCODE)" }
      } finally {
        Pop-Location
      }
    } else {
      Write-Host "influencor-web not found at $website; website not updated."
    }
  }
} finally {
  Pop-Location
}
