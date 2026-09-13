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

function Replace-TextOnce {
  param(
    [string]$Text,
    [string]$Old,
    [string]$New,
    [string]$Label
  )

  $first = $Text.IndexOf($Old, [System.StringComparison]::Ordinal)
  if ($first -lt 0) {
    throw "$Label target was not found"
  }
  $second = $Text.IndexOf($Old, $first + $Old.Length, [System.StringComparison]::Ordinal)
  if ($second -ge 0) {
    throw "$Label expected one target but found multiple"
  }
  return $Text.Substring(0, $first) + $New + $Text.Substring($first + $Old.Length)
}

# Win7 compatibility overlay: keep upstream source unchanged in git, but use a
# native main-window frame at build time. WebView2 109 + Win7 DWM can clip the
# top edge of frameless windows. The native frame also gives Win7 the normal
# taskbar/titlebar icon path. Preserve Simprint's app titlebar content, but hide
# its duplicate min/max/close buttons for this build.
$rootDir = if ($PSScriptRoot) { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path } else { $PWD }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$windowService = Join-Path $rootDir 'src-tauri/src/services/window/mod.rs'
$windowText = [IO.File]::ReadAllText($windowService)
$mainFramePattern = '(\.center\(\)\r?\n\s*)\.decorations\(false\)(\r?\n\s*\.visible\(false\))'
$mainFrameMatches = [regex]::Matches($windowText, $mainFramePattern)
if ($mainFrameMatches.Count -ne 1) {
  throw "Win7 main-window compatibility patch expected one target, found $($mainFrameMatches.Count)"
}
$windowText = [regex]::Replace($windowText, $mainFramePattern, '$1.decorations(true)$2', 1)
[IO.File]::WriteAllText($windowService, $windowText, $utf8NoBom)

$appLayout = Join-Path $rootDir 'plugins/layouts/app-layout/src/index.tsx'
$layoutText = [IO.File]::ReadAllText($appLayout)
if (-not $layoutText.Contains('<AppTitlebar />')) {
  throw 'Win7 titlebar compatibility patch target was not found'
}
$layoutText = $layoutText.Replace('<AppTitlebar />', '<AppTitlebar showWindowControls={false} />')
[IO.File]::WriteAllText($appLayout, $layoutText, $utf8NoBom)

# Tailwind 4's alpha-color output is not reliable on WebView2 109. The active
# sidebar row can therefore become a solid primary background while its label
# remains primary-colored, making the active text effectively invisible. Use a
# legacy-safe solid active state with explicit white foreground for Win7.
$sidebarPath = Join-Path $rootDir 'plugins/layouts/app-layout/src/components/app-sidebar.tsx'
$sidebarText = [IO.File]::ReadAllText($sidebarPath).Replace("`r`n", "`n")
$sidebarText = Replace-TextOnce $sidebarText `
  "? 'bg-primary/15 text-primary font-semibold border-primary'" `
  "? 'bg-primary text-white font-semibold border-primary'" `
  'Win7 active sidebar background'
$sidebarText = Replace-TextOnce $sidebarText `
  "`${isActive ? 'text-primary' : 'text-sidebar-foreground opacity-80'" `
  "`${isActive ? 'text-white' : 'text-sidebar-foreground opacity-80'" `
  'Win7 active sidebar icon foreground'
$sidebarText = Replace-TextOnce $sidebarText `
  "`${isActive ? 'text-primary' : 'text-sidebar-foreground/90'" `
  "`${isActive ? 'text-white' : 'text-sidebar-foreground/90'" `
  'Win7 active sidebar label foreground'
[IO.File]::WriteAllText($sidebarPath, $sidebarText, $utf8NoBom)

# Win7 release builds need actionable IO diagnostics. The generic 030000 code
# hid the underlying Windows error, which made runtime launch failures opaque.
$errorTypesPath = Join-Path $rootDir 'src-tauri/src/core/error/types.rs'
$errorTypes = [IO.File]::ReadAllText($errorTypesPath).Replace("`r`n", "`n")
$errorTypes = Replace-TextOnce $errorTypes `
  '#[error("[030000] IO error")]' `
  '#[error("[030000] IO error: {0}")]' `
  'Win7 IO error detail'
$frontendErrorOld = @'
    pub(super) fn format_for_frontend(&self) -> String {
        if cfg!(debug_assertions) {
            self.to_string()
        } else {
            format!("[{}]", self.code())
        }
    }
'@
$frontendErrorNew = @'
    pub(super) fn format_for_frontend(&self) -> String {
        if cfg!(debug_assertions) || cfg!(feature = "win7-offline") {
            self.to_string()
        } else {
            format!("[{}]", self.code())
        }
    }
'@
$errorTypes = Replace-TextOnce $errorTypes $frontendErrorOld $frontendErrorNew 'Win7 frontend error detail'
[IO.File]::WriteAllText($errorTypesPath, $errorTypes, $utf8NoBom)

# The Win7 bundle already carries a complete, pinned Supermium tree. Running
# the browser directly from Tauri's resource directory avoids first-launch
# staging/copy/remove/rename/marker writes that can surface as [030000] on
# locked or permission-sensitive Windows 7 profiles. Each environment still
# has its own --user-data-dir, so sharing the executable tree is safe.
$kernelServicePath = Join-Path $rootDir 'src-tauri/src/services/environment/kernel/mod.rs'
$kernelService = [IO.File]::ReadAllText($kernelServicePath).Replace("`r`n", "`n")
$kernelPattern = '(?s)    if find_executable\(&bundled_dir\)\.is_none\(\) \{\n        return Err\(format!\("安装包中的 Supermium 内核不完整: \{\}", bundled_dir\.display\(\)\)\.into\(\)\);\n    \}\n\n    let staging_dir = base\.join\(format!\(.*?\n    Ok\(kernel_dir\.join\(relative_exe\)\)'
$kernelMatches = [regex]::Matches($kernelService, $kernelPattern)
if ($kernelMatches.Count -ne 1) {
  throw "Win7 bundled Supermium direct-launch patch expected one target, found $($kernelMatches.Count)"
}
$kernelReplacement = @'
    let bundled_exe = find_executable(&bundled_dir)
        .ok_or_else(|| format!("安装包中的 Supermium 内核不完整: {}", bundled_dir.display()))?;
    Ok(bundled_exe)
'@
$kernelService = [regex]::Replace($kernelService, $kernelPattern, $kernelReplacement, 1)
[IO.File]::WriteAllText($kernelServicePath, $kernelService, $utf8NoBom)

# Git for Windows may materialize checked-out Rust sources as CRLF. The runtime
# overlay intentionally matches normalized LF source so its structural guards
# remain deterministic across runner images and core.autocrlf settings.
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

Write-Host 'Applied Win7 native-frame/titlebar, sidebar contrast, bundled-kernel, error-detail, and Supermium runtime compatibility overlays.'
