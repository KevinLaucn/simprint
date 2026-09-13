$ErrorActionPreference = 'Stop'

$target = 'x86_64-win7-windows-msvc'

# Rustc supports the Win7 Tier-3 target, but rustup does not distribute it and
# Tauri CLI rejects any target missing from `rustup target list` before Cargo runs.
$known = & rustc.exe --print target-list | Where-Object { $_ -eq $target }
if (-not $known) {
  throw "Current rustc does not know target $target"
}

$rustup = Get-Command rustup.exe -ErrorAction SilentlyContinue
if ($rustup) {
  $hidden = "$($rustup.Source).simprint-win7-hidden"
  if (Test-Path $hidden) {
    Remove-Item $hidden -Force
  }
  Move-Item -LiteralPath $rustup.Source -Destination $hidden -Force
  Write-Host "Temporarily hid rustup.exe so Tauri defers target handling to Cargo: $hidden"
}

# cargo.exe/rustc.exe are separate proxies and remain usable. Cargo uses
# .cargo/config.toml to build std from rust-src for the Tier-3 target.
& cargo.exe --version | Out-Host
if ($LASTEXITCODE -ne 0) {
  throw 'cargo.exe became unavailable after hiding rustup.exe'
}

$knownAfter = & rustc.exe --print target-list | Where-Object { $_ -eq $target }
if (-not $knownAfter) {
  throw "rustc stopped exposing $target after rustup.exe was hidden"
}

# Win7 compatibility overlay: keep upstream source unchanged in git, but use a
# native main-window frame at build time. WebView2 109 + Win7 DWM can clip the
# top edge of frameless windows. The native frame also gives Win7 the normal
# taskbar/titlebar icon path. Preserve Simprint's app titlebar content, but hide
# its duplicate min/max/close buttons for this build.
$rootDir = if ($PSScriptRoot) { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path } else { $PWD }
$windowService = Join-Path $rootDir 'src-tauri/src/services/window/mod.rs'
$windowText = [IO.File]::ReadAllText($windowService)
$mainFramePattern = '(\.center\(\)\r?\n\s*)\.decorations\(false\)(\r?\n\s*\.visible\(false\))'
$mainFrameMatches = [regex]::Matches($windowText, $mainFramePattern)
if ($mainFrameMatches.Count -ne 1) {
  throw "Win7 main-window compatibility patch expected one target, found $($mainFrameMatches.Count)"
}
$windowText = [regex]::Replace($windowText, $mainFramePattern, '$1.decorations(true)$2', 1)
[IO.File]::WriteAllText($windowService, $windowText, (New-Object System.Text.UTF8Encoding($false)))

$appLayout = Join-Path $rootDir 'plugins/layouts/app-layout/src/index.tsx'
$layoutText = [IO.File]::ReadAllText($appLayout)
if (-not $layoutText.Contains('<AppTitlebar />')) {
  throw 'Win7 titlebar compatibility patch target was not found'
}
$layoutText = $layoutText.Replace('<AppTitlebar />', '<AppTitlebar showWindowControls={false} />')
[IO.File]::WriteAllText($appLayout, $layoutText, (New-Object System.Text.UTF8Encoding($false)))

# Git for Windows may materialize checked-out Rust sources as CRLF. The runtime
# overlay intentionally matches normalized LF source so its structural guards
# remain deterministic across runner images and core.autocrlf settings.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$runtimeOverlaySources = @(
  'src-tauri/crates/runtime/src/services/environment/kernel/launcher.rs',
  'src-tauri/crates/runtime/src/services/environment/kernel/cdp.rs',
  'src-tauri/crates/runtime/src/services/environment/kernel/mod.rs'
)
foreach ($relativePath in $runtimeOverlaySources) {
  $sourcePath = Join-Path $rootDir $relativePath
  if (-not (Test-Path $sourcePath)) {
    throw "Win7 Supermium runtime overlay source was not found: $sourcePath"
  }
  $sourceText = [IO.File]::ReadAllText($sourcePath).Replace("`r`n", "`n")
  [IO.File]::WriteAllText($sourcePath, $sourceText, $utf8NoBom)
}

$runtimePatch = Join-Path $rootDir 'scripts/patch-win7-supermium-runtime.ps1'
if (-not (Test-Path $runtimePatch)) {
  throw "Win7 Supermium runtime patch script was not found: $runtimePatch"
}
& $runtimePatch

Write-Host 'Applied Win7 native-frame/titlebar and Supermium runtime compatibility overlays.'
