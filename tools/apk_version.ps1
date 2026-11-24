# Dot-sourcé par les scripts de build Android : `apk_version` de pubspec.yaml
# (« 0.5.0+2 ») donne le nom/numéro des APK du site, sans toucher `version`
# (AAB Play Store, Windows). Sans `apk_version`, les APK suivent `version`.
function Get-ApkVersion([string]$Repo) {
  $line = Get-Content -Path (Join-Path $Repo 'pubspec.yaml') |
    Where-Object { $_ -match '^apk_version:' } | Select-Object -First 1
  if (-not $line) { return $null }
  if ($line -notmatch '^apk_version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') {
    throw "apk_version invalide dans pubspec.yaml : '$line' (attendu X.Y.Z+N)"
  }
  return @{ Name = $Matches[1]; Number = $Matches[2] }
}

# Arguments `flutter build apk` (vide sans apk_version). Le dernier force le même
# versionCode (= numéro de build) pour tous les APK par architecture, au lieu de
# 1000 × ABI + build : arm64, armv7, x86_64 et universel ont tous le même numéro.
#
# Le canal `apk` est toujours ajouté : l'app lit alors `channels.apk.min_build`
# dans app-version.json du site (UpdateGate), pas celui de Google Play.
function Get-ApkBuildArgs([string]$Repo) {
  $channel = '--dart-define=INFLUENCOR_CHANNEL=apk'
  $v = Get-ApkVersion $Repo
  if (-not $v) { return @($channel) }
  return @(
    $channel,
    "--build-name=$($v.Name)",
    "--build-number=$($v.Number)",
    '--android-project-arg=force-version-code-ignoring-abi=true'
  )
}

# Libellé du dossier dist/releases (« 0.5.0_2 »), ou $null sans apk_version.
function Get-ApkVersionLabel([string]$Repo) {
  $v = Get-ApkVersion $Repo
  if (-not $v) { return $null }
  return "$($v.Name)_$($v.Number)"
}
