$ErrorActionPreference = 'Stop'

function Replace-RegexOnce {
  param(
    [string]$Text,
    [string]$Pattern,
    [string]$Replacement,
    [string]$Label
  )

  $regex = [regex]::new($Pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
  $matches = $regex.Matches($Text)
  if ($matches.Count -ne 1) {
    throw "$Label expected exactly one match, found $($matches.Count)"
  }
  return $regex.Replace(
    $Text,
    [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $Replacement },
    1
  )
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

$rootDir = if ($PSScriptRoot) { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path } else { $PWD }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Parallelize language/timezone proxy metadata detection. With a dead proxy the
# launch path now waits one timeout window instead of two serial windows.
$runtimeBridgePath = Join-Path $rootDir 'src-tauri/src/services/environment/kernel/runtime_bridge.rs'
$runtimeBridge = [IO.File]::ReadAllText($runtimeBridgePath).Replace("`r`n", "`n")
$parallelDetectionReplacement = @'
    if let Some(ref mut config) = fingerprint_config {
        let should_detect_language = match config.language.as_deref().map(str::trim) {
            Some(language) => language.is_empty() || language.eq_ignore_ascii_case("ip"),
            None => true,
        };
        let should_detect_timezone = match config.timezone.as_deref().map(str::trim) {
            Some(timezone) => timezone.is_empty() || timezone.eq_ignore_ascii_case("ip"),
            None => true,
        };

        let language_detection = async {
            if should_detect_language {
                language::detect_language(proxy.as_ref()).await
            } else {
                None
            }
        };
        let timezone_detection = async {
            if should_detect_timezone {
                timezone::detect_timezone(proxy.as_ref()).await
            } else {
                None
            }
        };
        let (detected_language, detected_timezone) =
            tokio::join!(language_detection, timezone_detection);

        if let Some(detected_language) = detected_language {
            config.language = Some(detected_language);
        }
        if let Some(detected_timezone) = detected_timezone {
            config.timezone = Some(detected_timezone);
        }
    }

    if let Some(ctx) = AppContext::try_get() {
'@
$runtimeBridge = Replace-RegexOnce $runtimeBridge `
  '    if let Some\(ref mut config\) = fingerprint_config \{.*?\n    \}\n\n    if let Some\(ctx\) = AppContext::try_get\(\) \{' `
  $parallelDetectionReplacement `
  'Win7 parallel proxy metadata detection'
[IO.File]::WriteAllText($runtimeBridgePath, $runtimeBridge, $utf8NoBom)

# The main runtime adapter has already been applied by patch-win7-supermium-runtime.ps1.
$launcherPath = Join-Path $rootDir 'src-tauri/crates/runtime/src/services/environment/kernel/launcher.rs'
$launcher = [IO.File]::ReadAllText($launcherPath).Replace("`r`n", "`n")

$spawnCallReplacement = @'
if request.use_eventbus { None } else { request.urls.as_deref() },
        if request.use_eventbus { None } else { request.fingerprint_config.as_ref() },
        request.extension_dirs.as_ref(),
'@
$launcher = Replace-RegexOnce $launcher `
  'if request\.use_eventbus \{ None \} else \{ request\.urls\.as_deref\(\) \},\s*request\.extension_dirs\.as_ref\(\),' `
  $spawnCallReplacement `
  'Win7 Supermium fingerprint spawn argument'

$spawnSignatureReplacement = @'
urls: Option<&[String]>,
    fingerprint_config: Option<&crate::infrastructure::eventbus::FingerprintConfig>,
    extension_dirs: Option<&Vec<String>>,
'@
$launcher = Replace-RegexOnce $launcher `
  'urls: Option<&\[String\]>,\s*extension_dirs: Option<&Vec<String>>,' `
  $spawnSignatureReplacement `
  'Win7 Supermium fingerprint spawn signature'

# Apply the stock-Chromium settings that do have stable command-line equivalents.
$fingerprintArgsOld = @'
    if let Some(size) = window_size {
        args.push(format!("--window-size={}", size));
    }
    if let Some(proxy) = proxy {
'@
$fingerprintArgsNew = @'
    if let Some(size) = window_size {
        args.push(format!("--window-size={}", size));
    }
    if let Some(config) = fingerprint_config {
        if let Some(user_agent) = config
            .user_agent
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            args.push(format!("--user-agent={}", user_agent));
        }
        let language = config
            .interface_language
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .or_else(|| {
                config
                    .language
                    .as_deref()
                    .map(str::trim)
                    .filter(|value| !value.is_empty() && !value.eq_ignore_ascii_case("ip"))
            });
        if let Some(language) = language {
            args.push(format!("--lang={}", language));
        }
        if config.sound == Some(false) {
            args.push("--mute-audio".to_string());
        }
        if config.images == Some(false) {
            args.push("--blink-settings=imagesEnabled=false".to_string());
        }
        if config.hardware_acceleration == Some(false) {
            args.push("--disable-gpu".to_string());
        }
        if config.disable_sandbox == Some(true) {
            args.push("--no-sandbox".to_string());
        }
        if let Some(parameters) = config
            .startup_parameters
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            for argument in parameters.split_whitespace().filter(|value| value.starts_with("--")) {
                args.push(argument.to_string());
            }
        }
    }
    if let Some(proxy) = proxy {
'@
$launcher = Replace-TextOnce $launcher $fingerprintArgsOld $fingerprintArgsNew 'Win7 Supermium standard fingerprint args'

# Manifest V3 normal extensions cannot request webRequestBlocking. The supported
# auth path uses webRequestAuthProvider + asyncBlocking.
$proxyAuthReplacement = @'
chrome.webRequest.onAuthRequired.addListener(
  (details, callback) => {
    if (!details.isProxy) {
      callback({});
      return;
    }
    callback({ authCredentials: { username: USERNAME, password: PASSWORD } });
  },
  { urls: ["<all_urls>"] },
  ["asyncBlocking"]
);
'@
$launcher = Replace-RegexOnce $launcher `
  'chrome\.webRequest\.onAuthRequired\.addListener\(\n  \(details\) => details\.isProxy.*?\n  \["blocking"\]\n\);' `
  $proxyAuthReplacement `
  'Win7 Manifest V3 proxy authentication handler'

# Closing the job object terminates the Supermium process tree, but termination
# is asynchronous. Wait briefly for CDP to disappear before marking the profile
# stopped, otherwise an immediate restart can race the old process/profile lock.
$shutdownReplacement = @'
// On Windows the JobHandle is configured with KILL_ON_JOB_CLOSE, so removing
    // the environment kills stock Supermium without requiring the patched EventBus.
    let shutdown_endpoint = cdp_endpoint_manager.get_endpoint(&env_id).await;
    job_manager.remove(&env_id).await;
    if let Some(endpoint) = shutdown_endpoint {
        if let Ok(client) = reqwest::Client::builder()
            .timeout(Duration::from_millis(200))
            .build()
        {
            let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
            loop {
                let still_alive = client
                    .get(&endpoint.version_url)
                    .send()
                    .await
                    .map(|response| response.status().is_success())
                    .unwrap_or(false);
                if !still_alive {
                    break;
                }
                if tokio::time::Instant::now() >= deadline {
                    log_warn(
                        "kernel",
                        format!("Supermium shutdown wait timed out for environment {}", env_id),
                    );
                    break;
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    }
    cdp_endpoint_manager.remove(&env_id).await;
'@
$launcher = Replace-RegexOnce $launcher `
  '// On Windows the JobHandle is configured with KILL_ON_JOB_CLOSE, so removing\n    // the environment kills stock Supermium without requiring the patched EventBus\.\n    job_manager\.remove\(&env_id\)\.await;\n    cdp_endpoint_manager\.remove\(&env_id\)\.await;' `
  $shutdownReplacement `
  'Win7 Supermium graceful shutdown wait'

# Keep unsupported live window resizing explicit instead of reporting a false
# EventBus connection failure. Initial position/size are already passed as flags.
$windowBoundsReplacement = @'
pub async fn set_window_bounds(request: WindowBoundsRequest, events: EventPublisher) -> Result<()> {
    let env_id = request.env_uuid.trim().to_string();
    let manager = eventbus_manager();

    if !manager.is_connected(&env_id).await {
        return Err(RuntimeError::Internal(
            "Stock Supermium 当前只在启动时应用窗口位置和尺寸；运行中调整窗口需要重启该环境"
                .into(),
        ));
    }

    let payload =
        encode_window_bounds_payload(request.x, request.y, request.width, request.height)?;
    let message = Message::event(Topic::WindowSetBounds, payload);
    manager.send(&env_id, &message).await?;

    let _ = events.emit(
        "environment.window_bounds_updated",
        &serde_json::json!({
            "env_uuid": env_id,
            "x": request.x,
            "y": request.y,
            "width": request.width,
            "height": request.height,
        }),
    );
    Ok(())
}

pub async fn get_connected_environments
'@
$launcher = Replace-RegexOnce $launcher `
  'pub async fn set_window_bounds\(request: WindowBoundsRequest, events: EventPublisher\) -> Result<\(\)> \{.*?\n\}\n\npub async fn get_connected_environments' `
  $windowBoundsReplacement `
  'Win7 Supermium window-bounds compatibility error'

[IO.File]::WriteAllText($launcherPath, $launcher, $utf8NoBom)

Write-Host 'Applied Win7 Supermium runtime v2 hardening: parallel metadata detection, standard fingerprint flags, MV3 proxy auth, shutdown wait, and explicit window-resize behavior.'
