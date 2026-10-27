$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$jbr = Join-Path $env:USERPROFILE '.jdks\jbr-21.0.11'
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
  flutter build apk --release @defines
  powershell -NoProfile -ExecutionPolicy Bypass -File $collector
} finally {
  Pop-Location
}
