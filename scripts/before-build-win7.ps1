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
$windowText = [IO.File]::ReadAllText($windowService).Replace("`r`n", "`n")
$mainFramePattern = '(\.center\(\)\r?\n\s*)\.decorations\(false\)(\r?\n\s*\.visible\(false\))'
$mainFrameMatches = [regex]::Matches($windowText, $mainFramePattern)
if ($mainFrameMatches.Count -ne 1) {
  throw "Win7 main-window compatibility patch expected one target, found $($mainFrameMatches.Count)"
}
$windowText = [regex]::Replace($windowText, $mainFramePattern, '$1.decorations(true)$2', 1)
$mainWindowBuildTarget = @'
                .build()?;

        log::info!(
            "Main window built in {:.1} ms",
'@
$mainWindowBuildReplacement = @'
                .build()?;

        // Win7 does not reliably inherit the bundle icon for dynamically built
        // webview windows. Set it explicitly so the title bar and taskbar use
        // the Simprint application identity.
        if let Some(icon) = app_handle.default_window_icon() {
            _window.set_icon(icon.clone())?;
        }

        log::info!(
            "Main window built in {:.1} ms",
'@
$windowText = Replace-TextOnce $windowText `
  $mainWindowBuildTarget `
  $mainWindowBuildReplacement `
  'Win7 explicit main-window icon'
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

# The create-window Chrome watermark used Tailwind's color-alpha syntax. On the
# pinned WebView2 109 runtime that alpha can be lost, turning a decorative 10%
# watermark into a foreground-colored shape that obscures the form. Use the
# legacy CSS opacity property instead and keep the mark intentionally subtle.
$windowInfoPath = Join-Path $rootDir 'plugins/pages/create-window/src/components/window-info-form.tsx'
$windowInfoText = [IO.File]::ReadAllText($windowInfoPath).Replace("`r`n", "`n")
$windowInfoText = Replace-TextOnce $windowInfoText `
  'className="w-96 h-96 text-muted-foreground/10"' `
  'className="w-96 h-96 text-muted-foreground opacity-[0.025]"' `
  'Win7 create-window watermark opacity'
[IO.File]::WriteAllText($windowInfoPath, $windowInfoText, $utf8NoBom)

# Win7 release builds need actionable IO diagnostics. The generic 030000 code
# hid the underlying Windows error, which made runtime launch failures opaque.
$errorTypesPath = Join-Path $rootDir 'src-tauri/src/core/error/types.rs'
$errorTypes = [IO.File]::ReadAllText($errorTypesPath).Replace("`r`n", "`n")
$errorTypes = Replace-TextOnce $errorTypes `
  '#[error("[030000] IO error")]' `
  '#[error("[030000] IO error: {0}")]' `
  'Win7 IO error detail'
$frontendErrorPattern = '(?s)(pub\(super\)\s+fn\s+format_for_frontend\(&self\)\s*->\s*String\s*\{.*?\bif\s+)cfg!\(debug_assertions\)\s*\{'
$frontendErrorMatches = [regex]::Matches($errorTypes, $frontendErrorPattern)
if ($frontendErrorMatches.Count -eq 1) {
  $errorTypes = [regex]::Replace(
    $errorTypes,
    $frontendErrorPattern,
    '$1cfg!(debug_assertions) || cfg!(feature = "win7-offline") {',
    1
  )
} elseif ($errorTypes.Contains('cfg!(debug_assertions) || cfg!(feature = "win7-offline")')) {
  Write-Host 'Win7 frontend error detail already applied'
} else {
  throw "Win7 frontend error detail target was not found exactly once (found $($frontendErrorMatches.Count))"
}
[IO.File]::WriteAllText($errorTypesPath, $errorTypes, $utf8NoBom)

# Win7 always launches the pinned Supermium directly from the Tauri resource
# directory. Do not resolve/create a profiles kernel directory, do not consult
# legacy marker files, and do not copy/rename the browser tree on first launch.
# This removes the remaining profile-path IO from kernel preparation and also
# prevents stale bundled copies from surviving an app update.
$kernelServicePath = Join-Path $rootDir 'src-tauri/src/services/environment/kernel/mod.rs'
$kernelService = [IO.File]::ReadAllText($kernelServicePath).Replace("`r`n", "`n")
$kernelPattern = '(?s)#\[cfg\(feature = "win7-offline"\)\]\nasync fn ensure_supermium_bundled\(.*?\n\}\n\nasync fn record_ready_installation'
$kernelMatches = [regex]::Matches($kernelService, $kernelPattern)
if ($kernelMatches.Count -ne 1) {
  throw "Win7 bundled Supermium direct-resource patch expected one target, found $($kernelMatches.Count)"
}
$kernelReplacement = @'
#[cfg(feature = "win7-offline")]
async fn ensure_supermium_bundled(
    app: &tauri::AppHandle,
    _env_uuid: &Option<String>,
    _install_dir_name: &str,
    _profiles_path: &str,
    _status_emitter: Option<&KernelStatusEmitter>,
) -> Result<std::path::PathBuf> {
    let mut candidate_dirs = Vec::new();
    if let Ok(res_dir) = app.path().resource_dir() {
        candidate_dirs.push(res_dir.join("supermium"));
        candidate_dirs.push(res_dir.join("resources").join("supermium"));
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            candidate_dirs.push(parent.join("supermium"));
            candidate_dirs.push(parent.join("resources").join("supermium"));
        }
    }

    let bundled_dir = candidate_dirs
        .into_iter()
        .find(|dir| dir.is_dir())
        .ok_or_else(|| "安装包缺少 Supermium 内核资源目录 (supermium)".to_string())?;

    let mut pending = vec![bundled_dir.clone()];
    while let Some(dir) = pending.pop() {
        for entry in fs::read_dir(&dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.is_dir() {
                pending.push(path);
                continue;
            }
            if path.file_name().is_some_and(|name| {
                name.eq_ignore_ascii_case("chrome.exe")
                    || name.eq_ignore_ascii_case("supermium.exe")
            }) {
                return Ok(path);
            }
        }
    }

    Err(format!("安装包中的 Supermium 内核不完整: {}", bundled_dir.display()).into())
}

async fn record_ready_installation
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

$runtimeV2Patch = Join-Path $rootDir 'scripts/patch-win7-supermium-runtime-v2.ps1'
if (-not (Test-Path $runtimeV2Patch)) {
  throw "Win7 Supermium runtime v2 patch script was not found: $runtimeV2Patch"
}
& $runtimeV2Patch

$runtimeV3Patch = Join-Path $rootDir 'scripts/patch-win7-supermium-runtime-v3.ps1'
if (-not (Test-Path $runtimeV3Patch)) {
  throw "Win7 Supermium runtime v3 patch script was not found: $runtimeV3Patch"
}
& $runtimeV3Patch
