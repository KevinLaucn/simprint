$ErrorActionPreference = 'Stop'

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

$rootDir = if ($PSScriptRoot) { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path } else { $PWD }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------------------
# Chromium 109 native Win7 runtime
# ---------------------------------------------------------------------------
# Keep this kernel completely separate from the Supermium resource. Chromium
# 109 is the final Chromium generation that supports Windows 7. We pin the
# original x64 Hibbiki build and verify its SHA256 before copying the installed
# Application tree into the Tauri resources directory.
$chromiumVersion = '109.0.5414.120'
$chromiumUrl = 'https://github.com/Hibbiki/chromium-win64/releases/download/v109.0.5414.120-r1070088/mini_installer.sync.exe'
$chromiumSha256 = 'E03C54DDB2614E70CC0D8622BE3568ABB9C11D8330FDF851FA39FF545B2F9CFF'
$chromiumInstaller = Join-Path $env:RUNNER_TEMP 'chromium-109-x64.exe'
$chromiumTarget = Join-Path $rootDir 'src-tauri/resources/chromium109'

Remove-Item $chromiumInstaller -Force -ErrorAction SilentlyContinue
& curl.exe -L --fail --retry 5 --retry-delay 2 --connect-timeout 30 --output $chromiumInstaller $chromiumUrl
if ($LASTEXITCODE -ne 0) {
  throw "Chromium 109 download failed with exit code $LASTEXITCODE"
}
if (-not (Test-Path $chromiumInstaller)) {
  throw 'Chromium 109 installer was not downloaded'
}
$actualChromiumHash = (Get-FileHash $chromiumInstaller -Algorithm SHA256).Hash.ToUpperInvariant()
if ($actualChromiumHash -ne $chromiumSha256) {
  throw "Chromium 109 SHA256 mismatch. Expected $chromiumSha256, got $actualChromiumHash"
}

$process = Start-Process -FilePath $chromiumInstaller -ArgumentList '--system-level --do-not-launch-chrome' -Wait -PassThru
if ($process.ExitCode -ne 0) {
  throw "Chromium 109 installer failed with exit code $($process.ExitCode)"
}

$applicationRoots = @()
if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
  $applicationRoots += (Join-Path $env:LOCALAPPDATA 'Chromium\Application')
}
if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
  $applicationRoots += (Join-Path ${env:ProgramFiles(x86)} 'Chromium\Application')
}
if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
  $applicationRoots += (Join-Path $env:ProgramFiles 'Chromium\Application')
}
$applicationRoot = $applicationRoots |
  Where-Object { Test-Path (Join-Path $_ 'chrome.exe') } |
  Select-Object -First 1
if (-not $applicationRoot) {
  throw "Chromium 109 installation completed but chrome.exe was not found under: $($applicationRoots -join ', ')"
}

$chromiumExe = Join-Path $applicationRoot 'chrome.exe'
$productVersion = (Get-Item $chromiumExe).VersionInfo.ProductVersion
if ([string]::IsNullOrWhiteSpace($productVersion) -or -not $productVersion.StartsWith($chromiumVersion)) {
  throw "Unexpected Chromium version at ${chromiumExe}: $productVersion"
}

Remove-Item $chromiumTarget -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $chromiumTarget | Out-Null
Copy-Item (Join-Path $applicationRoot '*') $chromiumTarget -Recurse -Force
if (-not (Test-Path (Join-Path $chromiumTarget 'chrome.exe'))) {
  throw 'Bundled Chromium 109 resource is incomplete: chrome.exe is missing'
}
Write-Host "Bundled native Chromium $productVersion from $applicationRoot"

# Add the Chromium directory to the generated Win7 Tauri config. This file was
# prepared before the overlay step, so patching it here keeps non-Win7 configs
# untouched.
$tauriConfigPath = Join-Path $rootDir 'src-tauri/tauri.conf.json'
$tauriConfig = Get-Content $tauriConfigPath -Raw | ConvertFrom-Json
if ($null -eq $tauriConfig.bundle.resources) {
  $tauriConfig.bundle | Add-Member -NotePropertyName resources -NotePropertyValue ([pscustomobject]@{}) -Force
}
$tauriConfig.bundle.resources |
  Add-Member -NotePropertyName 'resources/chromium109/' -NotePropertyValue 'chromium109/' -Force
$tauriJson = $tauriConfig | ConvertTo-Json -Depth 100
[IO.File]::WriteAllText($tauriConfigPath, $tauriJson + "`n", $utf8NoBom)

# ---------------------------------------------------------------------------
# Local kernel catalog: Win7 gets an explicit dual-kernel family.
# ---------------------------------------------------------------------------
$catalogPath = Join-Path $rootDir 'src-tauri/crates/business/resources/default-browser-kernels.json'
$catalog = Get-Content $catalogPath -Raw | ConvertFrom-Json
$win7Type = 'SIMPRINT_KERNEL_CHROMIUM_WIN7'
$existingWin7 = @($catalog.kernels | Where-Object { $_.type_code -eq $win7Type })
if ($existingWin7.Count -eq 0) {
  $supermiumRecord = [pscustomobject][ordered]@{
    type_code = $win7Type
    resource_name = 'Supermium 144 (Chromium 144)'
    install_dir_name = 'Supermium 144'
    version = '144.0.7559.118.5'
    name = 'supermium_144_64_nonsetup.zip'
    notes = 'Windows 7 compatibility kernel bundled with Simprint'
    platform = 'windows'
    url = 'https://github.com/win32ss/supermium/releases/download/v144-r5/supermium_144_64_nonsetup.zip'
    priority = 100
    hash = '805232e5cde1bf6971748bc7fb6a2cb09fdfce9ceb91062a1814b228139956ca'
    signature = '805232e5cde1bf6971748bc7fb6a2cb09fdfce9ceb91062a1814b228139956ca'
    compatible_signatures = @()
    file_size = $null
    is_latest = $true
    status = 'active'
    arch = 'x86_64'
    package_format = 'bundled'
    requires_extract = $false
    entrypoint_template = $null
    extract_root = $null
  }
  $chromiumRecord = [pscustomobject][ordered]@{
    type_code = $win7Type
    resource_name = 'Chromium 109 (Win7 Native)'
    install_dir_name = 'Chromium 109'
    version = $chromiumVersion
    name = 'mini_installer.sync.exe'
    notes = 'Native Chromium 109 x64, independent from the Supermium adapter'
    platform = 'windows'
    url = $chromiumUrl
    priority = 100
    hash = $chromiumSha256.ToLowerInvariant()
    signature = $chromiumSha256.ToLowerInvariant()
    compatible_signatures = @()
    file_size = $null
    is_latest = $false
    status = 'active'
    arch = 'x86_64'
    package_format = 'bundled'
    requires_extract = $false
    entrypoint_template = 'chrome.exe'
    extract_root = $null
  }
  $catalog.kernels += $supermiumRecord
  $catalog.kernels += $chromiumRecord
}
$catalogJson = $catalog | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($catalogPath, $catalogJson + "`n", $utf8NoBom)

# ---------------------------------------------------------------------------
# Create-window UI: Win7 queries its own kernel family instead of relabeling
# the normal Chromium 144 catalog as Supermium.
# ---------------------------------------------------------------------------
$windowInfoPath = Join-Path $rootDir 'plugins/pages/create-window/src/components/window-info-form.tsx'
$windowInfo = [IO.File]::ReadAllText($windowInfoPath).Replace("`r`n", "`n")
$oldKernelConstants = @'
const KERNEL_TYPE_CHROME = 'chrome';
const KERNEL_TYPE_FIREFOX = 'firefox';
const SIMPRINT_KERNEL_CHROMIUM = 'SIMPRINT_KERNEL_CHROMIUM';
const isWin7Supermium = import.meta.env.VITE_WIN7_SUPERMIUM === 'true';

function getKernelDisplayName(kernel: BrowserKernelVersion): string {
  const majorVersion = kernel.version.split('.')[0];
  return isWin7Supermium ? `Supermium ${majorVersion} (Chromium ${majorVersion})` : kernel.resource_name;
}
'@
$newKernelConstants = @'
const KERNEL_TYPE_CHROME = 'chrome';
const KERNEL_TYPE_FIREFOX = 'firefox';
const SIMPRINT_KERNEL_CHROMIUM = 'SIMPRINT_KERNEL_CHROMIUM';
const SIMPRINT_KERNEL_CHROMIUM_WIN7 = 'SIMPRINT_KERNEL_CHROMIUM_WIN7';
const isWin7DualKernel = import.meta.env.VITE_WIN7_SUPERMIUM === 'true';

function getKernelDisplayName(kernel: BrowserKernelVersion): string {
  return kernel.resource_name;
}
'@
$windowInfo = Replace-TextOnce $windowInfo $oldKernelConstants $newKernelConstants 'Win7 dual-kernel UI constants'
$windowInfo = Replace-TextOnce $windowInfo `
  '    listBrowserKernels(platform, SIMPRINT_KERNEL_CHROMIUM)' `
  "    const kernelTypeCode = isWin7DualKernel ? SIMPRINT_KERNEL_CHROMIUM_WIN7 : SIMPRINT_KERNEL_CHROMIUM;`n    listBrowserKernels(platform, kernelTypeCode)" `
  'Win7 dual-kernel catalog request'
$windowInfo = Replace-TextOnce $windowInfo `
  '        const versions = data[SIMPRINT_KERNEL_CHROMIUM] || [];' `
  '        const versions = data[kernelTypeCode] || [];' `
  'Win7 dual-kernel catalog response'
$windowInfo = Replace-TextOnce $windowInfo `
  "            (!currentInList || value.kernel === 'Chrome' || isWin7Supermium);" `
  "            (!currentInList || value.kernel === 'Chrome');" `
  'Win7 dual-kernel default selection'
[IO.File]::WriteAllText($windowInfoPath, $windowInfo, $utf8NoBom)

# ---------------------------------------------------------------------------
# Kernel preparation: keep Supermium and Chromium 109 physically and logically
# separate. Legacy Win7 environments that were previously bound to Chrome 144
# continue to map to Supermium so existing profiles are not broken.
# ---------------------------------------------------------------------------
$kernelServicePath = Join-Path $rootDir 'src-tauri/src/services/environment/kernel/mod.rs'
$kernelService = [IO.File]::ReadAllText($kernelServicePath).Replace("`r`n", "`n")
if (-not $kernelService.Contains('async fn ensure_chromium109_bundled(')) {
  $chromiumResolver = @'

#[cfg(feature = "win7-offline")]
async fn ensure_chromium109_bundled(
    app: &tauri::AppHandle,
    _env_uuid: &Option<String>,
    _install_dir_name: &str,
    _profiles_path: &str,
    _status_emitter: Option<&KernelStatusEmitter>,
) -> Result<std::path::PathBuf> {
    let mut candidate_dirs = Vec::new();
    if let Ok(res_dir) = app.path().resource_dir() {
        candidate_dirs.push(res_dir.join("chromium109"));
        candidate_dirs.push(res_dir.join("resources").join("chromium109"));
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            candidate_dirs.push(parent.join("chromium109"));
            candidate_dirs.push(parent.join("resources").join("chromium109"));
        }
    }

    let bundled_dir = candidate_dirs
        .into_iter()
        .find(|dir| dir.is_dir())
        .ok_or_else(|| "安装包缺少 Chromium 109 内核资源目录 (chromium109)".to_string())?;

    let direct_exe = bundled_dir.join("chrome.exe");
    if direct_exe.is_file() {
        return Ok(direct_exe);
    }

    let mut pending = vec![bundled_dir.clone()];
    while let Some(dir) = pending.pop() {
        for entry in fs::read_dir(&dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.is_dir() {
                pending.push(path);
                continue;
            }
            if path.file_name().is_some_and(|name| name.eq_ignore_ascii_case("chrome.exe")) {
                return Ok(path);
            }
        }
    }

    Err(format!("安装包中的 Chromium 109 内核不完整: {}", bundled_dir.display()).into())
}
'@
  $kernelService = Replace-TextOnce $kernelService `
    "`nasync fn record_ready_installation" `
    ($chromiumResolver + "`nasync fn record_ready_installation") `
    'Win7 Chromium 109 bundled resolver'
}

$oldWin7Prepare = @'
        #[cfg(feature = "win7-offline")]
        {
            let exe_path = ensure_supermium_bundled(
                &app,
                &env_uuid,
                &install_dir_name,
                &profiles_path,
                status_emitter.as_ref(),
            )
            .await?;
            utils::emit_status(
                status_emitter.as_ref(),
                &env_uuid,
                &install_dir_name,
                EnvironmentStatus::Ready,
                Some("Supermium 固定内核已就绪"),
                None,
                None,
                None,
            );
            record_ready_installation(&app, &kernel_id, &exe_path, "supermium-win7-bundled").await;
            return Ok(exe_path.to_string_lossy().to_string());
        }
'@
$newWin7Prepare = @'
        #[cfg(feature = "win7-offline")]
        {
            let bundled = if install_dir_name.eq_ignore_ascii_case("Chromium 109") {
                let exe_path = ensure_chromium109_bundled(
                    &app,
                    &env_uuid,
                    &install_dir_name,
                    &profiles_path,
                    status_emitter.as_ref(),
                )
                .await?;
                Some((exe_path, "Chromium 109 原生内核已就绪", "chromium-109-win7-bundled"))
            } else if install_dir_name.eq_ignore_ascii_case("Supermium 144")
                || install_dir_name.eq_ignore_ascii_case("Chrome 144")
            {
                let exe_path = ensure_supermium_bundled(
                    &app,
                    &env_uuid,
                    &install_dir_name,
                    &profiles_path,
                    status_emitter.as_ref(),
                )
                .await?;
                Some((exe_path, "Supermium 固定内核已就绪", "supermium-win7-bundled"))
            } else {
                None
            };

            if let Some((exe_path, message, verified_signature)) = bundled {
                utils::emit_status(
                    status_emitter.as_ref(),
                    &env_uuid,
                    &install_dir_name,
                    EnvironmentStatus::Ready,
                    Some(message),
                    None,
                    None,
                    None,
                );
                record_ready_installation(&app, &kernel_id, &exe_path, verified_signature).await;
                return Ok(exe_path.to_string_lossy().to_string());
            }
        }
'@
$kernelService = Replace-TextOnce $kernelService $oldWin7Prepare $newWin7Prepare 'Win7 independent dual-kernel preparation'
[IO.File]::WriteAllText($kernelServicePath, $kernelService, $utf8NoBom)

Write-Host 'Applied Win7 dual-kernel overlay: Supermium 144 + independent native Chromium 109.'
