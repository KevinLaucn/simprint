$ErrorActionPreference = 'Stop'

$rootDir = if ($PSScriptRoot) { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path } else { $PWD }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$launcherPath = Join-Path $rootDir 'src-tauri/crates/runtime/src/services/environment/kernel/launcher.rs'
$launcher = [IO.File]::ReadAllText($launcherPath).Replace("`r`n", "`n")

function Invoke-DualKernelPatch {
  $dualKernelPatch = Join-Path $PSScriptRoot 'patch-win7-dual-kernel.ps1'
  if (-not (Test-Path $dualKernelPatch)) {
    throw "Win7 dual-kernel patch script was not found: $dualKernelPatch"
  }

  # Git for Windows may check PowerShell scripts out as CRLF. The dual-kernel
  # overlay normalizes its TS/Rust targets to LF before matching them, so its
  # own multi-line here-strings must be parsed from LF source as well.
  $dualKernelText = [IO.File]::ReadAllText($dualKernelPatch).Replace("`r`n", "`n")
  [IO.File]::WriteAllText($dualKernelPatch, $dualKernelText, $utf8NoBom)
  & $dualKernelPatch
}

function Invoke-DiagnosticsPatch {
  $diagnosticsPatch = Join-Path $PSScriptRoot 'patch-win7-supermium-runtime-v4.ps1'
  if (-not (Test-Path $diagnosticsPatch)) {
    throw "Win7 environment diagnostics patch script was not found: $diagnosticsPatch"
  }
  & $diagnosticsPatch
}

# User-defined startup parameters remain supported, but they must not be able to
# override the flags that enforce profile isolation, CDP ownership, proxy routing,
# extension loading, or Simprint environment identity.
$guardMarker = 'Ignoring reserved Supermium startup flag: {}'
if ($launcher.Contains($guardMarker)) {
  Write-Host 'Win7 Supermium runtime v3 isolation guard already applied.'
  Invoke-DualKernelPatch
  Invoke-DiagnosticsPatch
  exit 0
}

$pattern = 'for argument in parameters\.split_whitespace\(\)\.filter\(\|value\| value\.starts_with\("--"\)\)\s*\{\s*args\.push\(argument\.to_string\(\)\);\s*\}'
$regex = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
$matches = $regex.Matches($launcher)
if ($matches.Count -ne 1) {
  throw "Win7 reserved Chromium startup flags expected exactly one startup-parameter loop, found $($matches.Count)"
}

$guardedLoop = @'
for argument in parameters.split_whitespace().filter(|value| value.starts_with("--")) {
                let flag_name = argument
                    .split_once('=')
                    .map(|(name, _)| name)
                    .unwrap_or(argument)
                    .to_ascii_lowercase();
                let reserved = matches!(
                    flag_name.as_str(),
                    "--user-data-dir"
                        | "--profile-directory"
                        | "--remote-debugging-port"
                        | "--remote-allow-origins"
                        | "--proxy-server"
                        | "--proxy-bypass-list"
                        | "--load-extension"
                        | "--disable-extensions-except"
                        | "--simprint-env-id"
                        | "--simprint-display-id"
                        | "--window-position"
                        | "--window-size"
                );
                if reserved {
                    log_warn(
                        "kernel",
                        format!("Ignoring reserved Supermium startup flag: {}", flag_name),
                    );
                    continue;
                }
                args.push(argument.to_string());
            }
'@

$launcher = $regex.Replace(
  $launcher,
  [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $guardedLoop },
  1
)

if (-not $launcher.Contains($guardMarker)) {
  throw 'Win7 reserved Chromium startup flags guard was not applied'
}

[IO.File]::WriteAllText($launcherPath, $launcher, $utf8NoBom)
Write-Host 'Applied Win7 Supermium runtime v3 isolation guard for custom startup flags.'

# Keep the dual-kernel overlay as the final kernel/runtime transformation, then
# add diagnostics against that final launcher shape so the patch is deterministic.
Invoke-DualKernelPatch
Invoke-DiagnosticsPatch
