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
  return $regex.Replace($Text, $Replacement, 1)
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

# WebView2 109 cannot parse Tailwind 4 color-mix()/OKLCH reliably. Resolve
# chained theme variables (for example --color-primary -> --primary -> #hex)
# and accept both fractional and percentage OKLCH lightness values.
$vitePath = Join-Path $rootDir 'vite.config.ts'
$vite = [IO.File]::ReadAllText($vitePath).Replace("`r`n", "`n")
$legacyColorReplacement = @'
function oklchToCss(
  lightness: string,
  lightnessIsPercent: boolean,
  chroma: string,
  hue: string,
  alpha?: string
) {
  const rawLightness = Number(lightness);
  const l = lightnessIsPercent ? rawLightness / 100 : rawLightness;
  const c = Number(chroma);
  const h = (Number(hue) * Math.PI) / 180;
  const a = c * Math.cos(h);
  const b = c * Math.sin(h);
  const l_ = l + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = l - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = l - 0.0894841775 * a - 1.291485548 * b;
  const l3 = l_ * l_ * l_;
  const m3 = m_ * m_ * m_;
  const s3 = s_ * s_ * s_;
  const r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309692326 * s3;
  const g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3;
  const bChannel = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.707614701 * s3;
  const gamma = (value: number) =>
    value <= 0.0031308 ? 12.92 * value : 1.055 * Math.pow(value, 1 / 2.4) - 0.055;
  const channel = (value: number) => Math.round(Math.max(0, Math.min(1, gamma(value))) * 255);
  const rgb = [channel(r), channel(g), channel(bChannel)];
  if (alpha === undefined)
    return `#${rgb.map((value) => value.toString(16).padStart(2, '0')).join('')}`;
  const opacity = alpha.endsWith('%') ? Number.parseFloat(alpha) / 100 : Number.parseFloat(alpha);
  return `rgba(${rgb.join(',')},${Math.max(0, Math.min(1, opacity))})`;
}

function replaceLegacyOklch(css: string) {
  return css.replace(
    /oklch\(\s*([+-]?[\d.]+)(%)?\s+([+-]?[\d.]+)\s+([+-]?[\d.]+)(?:deg)?(?:\s*\/\s*([+-]?[\d.]+%?))?\s*\)/g,
    (_match, lightness, percent, chroma, hue, alpha) =>
      oklchToCss(lightness, percent === '%', chroma, hue, alpha)
  );
}

function normalizeHexColor(value: string | undefined) {
  if (!value) return undefined;
  const match = value.trim().match(/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i);
  if (!match) return undefined;
  let hex = match[1];
  if (hex.length === 3) hex = hex.split('').map((char) => char + char).join('');
  return `#${hex.slice(0, 6)}`;
}

function hexToRgba(hex: string, alpha: number) {
  const channels = [1, 3, 5].map((index) => Number.parseInt(hex.slice(index, index + 2), 16));
  return `rgba(${channels.join(',')},${Math.max(0, Math.min(1, alpha))})`;
}

function replaceLegacyColorMix(css: string) {
  const variables = new Map<string, string>([
    ['background', '#ffffff'],
    ['foreground', '#333333'],
    ['muted', '#f9fafb'],
    ['muted-foreground', '#6b7280'],
    ['accent', '#e0f2fe'],
    ['accent-foreground', '#1e3a8a'],
    ['border', '#e5e7eb'],
    ['input', '#e5e7eb'],
    ['primary', '#3b82f6'],
    ['primary-foreground', '#ffffff'],
    ['destructive', '#ef4444'],
    ['sidebar', '#f9fafb'],
    ['sidebar-foreground', '#333333'],
    ['sidebar-primary', '#3b82f6'],
    ['sidebar-primary-foreground', '#ffffff'],
    ['sidebar-accent', '#e0f2fe'],
    ['sidebar-border', '#e5e7eb'],
  ]);

  for (const match of css.matchAll(/--([\w-]+)\s*:\s*([^;{}]+);/g)) {
    variables.set(match[1], match[2].trim());
  }

  const resolveVariableColor = (name: string, seen = new Set<string>()): string | undefined => {
    if (seen.has(name)) return undefined;
    seen.add(name);
    const value = variables.get(name)?.trim();
    const directHex = normalizeHexColor(value);
    if (directHex) return directHex;
    if (!value) return undefined;
    const reference = value.match(/^var\(--([\w-]+)(?:\s*,\s*([^)]+))?\)$/);
    if (!reference) return undefined;
    return (
      resolveVariableColor(reference[1], seen) ||
      (reference[2] ? normalizeHexColor(reference[2]) : undefined)
    );
  };

  let output = css.replace(
    /color-mix\(in\s+(?:oklab|srgb),\s*var\(--([\w-]+)\)\s+([\d.]+)%\s*,\s*transparent\s*\)/gi,
    (_match, name: string, alpha: string) => {
      const color = resolveVariableColor(name);
      return color ? hexToRgba(color, Number.parseFloat(alpha) / 100) : `var(--${name})`;
    }
  );

  output = output.replace(
    /color-mix\(in\s+(?:oklab|srgb),\s*transparent\s*,\s*var\(--([\w-]+)\)\s+([\d.]+)%\s*\)/gi,
    (_match, name: string, alpha: string) => {
      const color = resolveVariableColor(name);
      return color ? hexToRgba(color, Number.parseFloat(alpha) / 100) : `var(--${name})`;
    }
  );

  output = output.replace(
    /color-mix\(in\s+(?:oklab|srgb),\s*currentColor\s+[\d.]+%\s*,\s*transparent\s*\)/gi,
    'currentColor'
  );

  output = output.replace(
    /color-mix\(in\s+(?:oklab|srgb),\s*(#[0-9a-f]{3,8})\s+([\d.]+)%\s*,\s*transparent\s*\)/gi,
    (match, rawColor: string, alpha: string) => {
      const color = normalizeHexColor(rawColor);
      return color ? hexToRgba(color, Number.parseFloat(alpha) / 100) : match;
    }
  );

  return output;
}

function win7LegacyCssPlugin()
'@
$vite = Replace-RegexOnce $vite `
  'function oklchToCss\(.*?\n\}\n\nfunction win7LegacyCssPlugin\(\)' `
  $legacyColorReplacement `
  'Win7 legacy CSS color conversion'
[IO.File]::WriteAllText($vitePath, $vite, $utf8NoBom)

# A stale local Mihomo binding must never silently degrade to direct browsing.
# Reuse the environment's configured remote proxy when the local listener is gone.
$launchRuntimePath = Join-Path $rootDir 'src-tauri/src/services/environment/launch_runtime/mod.rs'
$launchRuntime = [IO.File]::ReadAllText($launchRuntimePath).Replace("`r`n", "`n")
$proxyResolutionReplacement = @'
fn resolve_environment_proxy_config(
    app: &AppHandle,
    env_uuid: &str,
    remote_proxy: Option<EnvironmentProxyLike>,
) -> Option<ProxyConfig> {
    let remote_proxy = build_tauri_proxy_config(remote_proxy);
    match resolve_local_proxy_config(app, env_uuid) {
        LocalProxyResolution::Resolved(proxy) => Some(proxy),
        LocalProxyResolution::MissingBindingTarget => {
            if remote_proxy.is_some() {
                log::warn!(
                    "local proxy binding is stale for env_uuid={}; falling back to configured remote proxy",
                    env_uuid
                );
            } else {
                log::warn!(
                    "local proxy binding is stale for env_uuid={} and no remote proxy is configured",
                    env_uuid
                );
            }
            remote_proxy
        }
        LocalProxyResolution::NoBinding => remote_proxy,
    }
}

fn resolve_local_proxy_config
'@
$launchRuntime = Replace-RegexOnce $launchRuntime `
  'fn resolve_environment_proxy_config\(.*?\n\}\n\nfn resolve_local_proxy_config' `
  $proxyResolutionReplacement `
  'Win7 stale local proxy fallback'
$remoteProxyReplacement = @'
fn build_tauri_proxy_config(proxy: Option<EnvironmentProxyLike>) -> Option<ProxyConfig> {
    let proxy = proxy?;
    let host = proxy.host?.trim().to_string();
    let port = proxy.port?;
    if host.is_empty() || port == 0 {
        log::warn!("ignoring invalid remote proxy configuration: host/port is empty");
        return None;
    }

    Some(ProxyConfig {
        host,
        port,
        proxy_type: proxy.proxy_type.unwrap_or_else(|| "http".to_string()),
        username: proxy.username,
        password: proxy.password.map(crate::infrastructure::proxy::types::ProxyPassword::plain),
    })
}

fn normalize_accounts
'@
$launchRuntime = Replace-RegexOnce $launchRuntime `
  'fn build_tauri_proxy_config\(.*?\n\}\n\nfn normalize_accounts' `
  $remoteProxyReplacement `
  'Win7 remote proxy validation'
[IO.File]::WriteAllText($launchRuntimePath, $launchRuntime, $utf8NoBom)

# With an explicitly configured proxy, IP-derived language/timezone must not
# fall back to a direct connection. A direct fallback both leaks the host IP and
# produces a fingerprint that disagrees with the proxy egress.
$languagePath = Join-Path $rootDir 'src-tauri/src/services/environment/kernel/language.rs'
$language = [IO.File]::ReadAllText($languagePath).Replace("`r`n", "`n")
$languageProxyReplacement = @'
async fn detect_with_proxy(proxy_cfg: &ProxyConfig) -> Option<String> {
    let infra_proxy_cfg = proxy_cfg.to_infrastructure_proxy_config();
    let proxy_client = match crate::infrastructure::proxy::client::build_proxy_client(
        &infra_proxy_cfg,
        Some(TIMEZONE_DETECTION_TIMEOUT_SECS),
    ) {
        Ok(client) => client,
        Err(error) => {
            log::warn!("proxy language detection client initialization failed: {}", error);
            return None;
        }
    };

    let proxy_result = crate::infrastructure::proxy::detector::detect_ip_with_timeout(
        proxy_client,
        TIMEZONE_DETECTION_TIMEOUT_SECS,
    )
    .await;

    if proxy_result.success {
        let ip_info = proxy_result.ip_info.as_ref()?;
        infer_language_from_country_code(ip_info.country_code.as_str())
    } else {
        log::warn!("proxy language detection failed; direct fallback is disabled");
        None
    }
}

async fn detect_with_system_proxy
'@
$language = Replace-RegexOnce $language `
  'async fn detect_with_proxy\(.*?\n\}\n\nasync fn detect_with_system_proxy' `
  $languageProxyReplacement `
  'Win7 proxy language no-direct-fallback'
[IO.File]::WriteAllText($languagePath, $language, $utf8NoBom)

$timezonePath = Join-Path $rootDir 'src-tauri/src/services/environment/kernel/timezone.rs'
$timezone = [IO.File]::ReadAllText($timezonePath).Replace("`r`n", "`n")
$timezoneProxyReplacement = @'
async fn detect_with_proxy(proxy_cfg: &ProxyConfig) -> Option<String> {
    let infra_proxy_cfg = proxy_cfg.to_infrastructure_proxy_config();
    let proxy_client = match crate::infrastructure::proxy::client::build_proxy_client(
        &infra_proxy_cfg,
        Some(TIMEZONE_DETECTION_TIMEOUT_SECS),
    ) {
        Ok(client) => client,
        Err(error) => {
            log::warn!("proxy timezone detection client initialization failed: {}", error);
            return None;
        }
    };

    let proxy_result = crate::infrastructure::proxy::detector::detect_ip_with_timeout(
        proxy_client,
        TIMEZONE_DETECTION_TIMEOUT_SECS,
    )
    .await;

    if proxy_result.success {
        Some(proxy_result.timezone)
    } else {
        log::warn!("proxy timezone detection failed; direct fallback is disabled");
        None
    }
}

async fn detect_with_system_proxy
'@
$timezone = Replace-RegexOnce $timezone `
  'async fn detect_with_proxy\(.*?\n\}\n\nasync fn detect_with_system_proxy' `
  $timezoneProxyReplacement `
  'Win7 proxy timezone no-direct-fallback'
[IO.File]::WriteAllText($timezonePath, $timezone, $utf8NoBom)

# Run the two proxy metadata probes concurrently. A dead proxy now costs one
# timeout window rather than two serial timeout windows before Supermium starts.
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

# Harden the already-generated stock-Supermium runtime adapter.
$launcherPath = Join-Path $rootDir 'src-tauri/crates/runtime/src/services/environment/kernel/launcher.rs'
$launcher = [IO.File]::ReadAllText($launcherPath).Replace("`r`n", "`n")

$launcher = Replace-RegexOnce $launcher `
  'if request\.use_eventbus \{ None \} else \{ request\.urls\.as_deref\(\) \},\s*request\.extension_dirs\.as_ref\(\),' `
  'if request.use_eventbus { None } else { request.urls.as_deref() },`n        if request.use_eventbus { None } else { request.fingerprint_config.as_ref() },`n        request.extension_dirs.as_ref(),' `
  'Win7 Supermium fingerprint spawn argument'

$launcher = Replace-RegexOnce $launcher `
  'urls: Option<&\[String\]>,\s*extension_dirs: Option<&Vec<String>>,' `
  'urls: Option<&[String]>,`n    fingerprint_config: Option<&crate::infrastructure::eventbus::FingerprintConfig>,`n    extension_dirs: Option<&Vec<String>>,' `
  'Win7 Supermium fingerprint spawn signature'

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

Write-Host 'Applied Win7 hardening overlay: legacy CSS colors, proxy fallback/privacy, parallel metadata detection, MV3 proxy auth, fingerprint args, and shutdown wait.'
