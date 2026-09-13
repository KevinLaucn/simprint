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
$launcherPath = Join-Path $rootDir 'src-tauri/crates/runtime/src/services/environment/kernel/launcher.rs'
$launcher = [IO.File]::ReadAllText($launcherPath).Replace("`r`n", "`n")

# User-defined startup parameters remain supported, but they must not be able to
# override the flags that enforce profile isolation, CDP ownership, proxy routing,
# extension loading, or Simprint environment identity.
$old = @'
            for argument in parameters.split_whitespace().filter(|value| value.starts_with("--")) {
                args.push(argument.to_string());
            }
'@
$new = @'
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
$launcher = Replace-TextOnce $launcher $old $new 'Win7 reserved Chromium startup flags'
[IO.File]::WriteAllText($launcherPath, $launcher, $utf8NoBom)

Write-Host 'Applied Win7 Supermium runtime v3 isolation guard for custom startup flags.'
