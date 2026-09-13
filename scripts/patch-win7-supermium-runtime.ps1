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

$rootDir = if ($PSScriptRoot) { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path } else { $PWD }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$launcherPath = Join-Path $rootDir 'src-tauri/crates/runtime/src/services/environment/kernel/launcher.rs'
$launcher = [IO.File]::ReadAllText($launcherPath)

$launcher = Replace-RegexOnce $launcher `
  'BatchLaunchResult, CdpEndpointResponse, EnvironmentStartRequest, RpaTabCloseResult,\s*RpaTabSelection, RpaTabsSnapshot, WindowBoundsRequest,' `
  'BatchLaunchResult, BrowserProxyConfigPayload, CdpEndpointResponse, EnvironmentStartRequest, RpaTabCloseResult, RpaTabInfo, RpaTabSelection, RpaTabsSnapshot, WindowBoundsRequest,' `
  'Win7 Supermium runtime type imports'

$spawnCallReplacement = @'
request.window_size.as_deref(),
        if request.use_eventbus { None } else { request.proxy.as_ref() },
        if request.use_eventbus { None } else { request.urls.as_deref() },
        request.extension_dirs.as_ref(),
        job_manager.clone(),
'@
$launcher = Replace-RegexOnce $launcher `
  'request\.window_size\.as_deref\(\),\s*request\.extension_dirs\.as_ref\(\),\s*job_manager\.clone\(\),' `
  $spawnCallReplacement `
  'Win7 Supermium spawn request arguments'

$watcherReplacement = @'
let watched_env_id = env_id.clone();
    let watched_cdp = cdp_endpoint_manager.clone();
    let watched_jobs = job_manager.clone();
    let watched_status = status_manager.clone();
    let watched_events = events.clone();
    tokio::spawn(async move {
        match browser.wait().await {
            Ok(status) => log_info(
                "kernel",
                format!(
                    "Browser process exited for environment {}: {}",
                    watched_env_id, status
                ),
            ),
            Err(error) => log_warn(
                "kernel",
                format!(
                    "Failed to wait for browser process for environment {}: {}",
                    watched_env_id, error
                ),
            ),
        }

        watched_jobs.remove(&watched_env_id).await;
        watched_cdp.remove(&watched_env_id).await;
        watched_status.set_stopped_unless_error(&watched_env_id).await;
        let _ = watched_events.emit(
            "environment.browser_disconnected",
            &serde_json::json!({ "env_uuid": watched_env_id }),
        );
    });

    log_info(
'@
$launcher = Replace-RegexOnce $launcher `
  'let watched_env_id = env_id\.clone\(\);.*?\n\s*\}\);\s*\n\s*log_info\(' `
  $watcherReplacement `
  'Win7 Supermium process watcher cleanup'

$spawnSignatureReplacement = @'
window_size: Option<&str>,
    proxy: Option<&BrowserProxyConfigPayload>,
    urls: Option<&[String]>,
    extension_dirs: Option<&Vec<String>>,
'@
$launcher = Replace-RegexOnce $launcher `
  'window_size: Option<&str>,\s*extension_dirs: Option<&Vec<String>>,' `
  $spawnSignatureReplacement `
  'Win7 Supermium spawn signature'

$spawnRuntimeReplacement = @'
if let Some(proxy) = proxy {
        if proxy.mode.eq_ignore_ascii_case("fixed_servers") {
            let server = proxy.server.trim();
            if !server.is_empty() {
                args.push(format!("--proxy-server={}", server));
                log_info("kernel", format!("Applying Supermium proxy server: {}", server));
            }
        }
        if let Some(bypass_list) = proxy.bypass_list.as_deref() {
            let bypass_list = bypass_list.trim();
            if !bypass_list.is_empty() {
                args.push(format!("--proxy-bypass-list={}", bypass_list));
            }
        }
    }

    let mut launch_extension_dirs = extension_dirs.cloned().unwrap_or_default();
    if let Some(proxy) = proxy {
        if let Some(proxy_auth_dir) = prepare_proxy_auth_extension(user_data_dir, proxy)? {
            launch_extension_dirs.push(proxy_auth_dir);
        }
    }

    if !launch_extension_dirs.is_empty() {
        args.push(format!("--load-extension={}", launch_extension_dirs.join(",")));
        log_info(
            "kernel",
            format!(
                "Loading {} extensions: {}",
                launch_extension_dirs.len(),
                launch_extension_dirs.join(", ")
            ),
        );
    }

    if let Some(urls) = urls {
        for url in urls {
            let url = url.trim();
            if !url.is_empty() {
                args.push(url.to_string());
            }
        }
    }

    let mut command = tokio::process::Command::new(exe_path);
'@
$launcher = Replace-RegexOnce $launcher `
  'if let Some\(dirs\) = extension_dirs \{.*?\n\s*\}\s*\n\s*let mut command = tokio::process::Command::new\(exe_path\);' `
  $spawnRuntimeReplacement `
  'Win7 Supermium proxy/url/extension launch bridge'

$proxyAuthHelper = @'

fn prepare_proxy_auth_extension(
    user_data_dir: &str,
    proxy: &BrowserProxyConfigPayload,
) -> Result<Option<String>> {
    let Some(auth) = proxy.auth.as_ref() else {
        return Ok(None);
    };
    let Some(credentials) = auth.values().next() else {
        return Ok(None);
    };

    let extension_dir = Path::new(user_data_dir).join("simprint_proxy_auth");
    std::fs::create_dir_all(&extension_dir).map_err(|error| {
        RuntimeError::Internal(format!(
            "failed to create Supermium proxy auth extension directory {}: {}",
            extension_dir.display(),
            error
        ))
    })?;

    let manifest = serde_json::json!({
        "manifest_version": 3,
        "name": "Simprint Proxy Auth",
        "version": "1.0.0",
        "permissions": ["webRequest", "webRequestAuthProvider"],
        "host_permissions": ["<all_urls>"],
        "background": { "service_worker": "background.js" }
    });
    let manifest_bytes = serde_json::to_vec_pretty(&manifest)
        .map_err(|error| RuntimeError::Internal(format!("failed to serialize proxy auth manifest: {error}")))?;
    std::fs::write(extension_dir.join("manifest.json"), manifest_bytes).map_err(|error| {
        RuntimeError::Internal(format!("failed to write proxy auth manifest: {error}"))
    })?;

    let username = serde_json::to_string(&credentials.username)
        .map_err(|error| RuntimeError::Internal(format!("failed to encode proxy username: {error}")))?;
    let password = serde_json::to_string(&credentials.password)
        .map_err(|error| RuntimeError::Internal(format!("failed to encode proxy password: {error}")))?;
    let background = r#"const USERNAME = __SIMPRINT_PROXY_USERNAME__;
const PASSWORD = __SIMPRINT_PROXY_PASSWORD__;
chrome.webRequest.onAuthRequired.addListener(
  (details) => details.isProxy
    ? { authCredentials: { username: USERNAME, password: PASSWORD } }
    : {},
  { urls: ["<all_urls>"] },
  ["blocking"]
);
"#
    .replace("__SIMPRINT_PROXY_USERNAME__", &username)
    .replace("__SIMPRINT_PROXY_PASSWORD__", &password);
    std::fs::write(extension_dir.join("background.js"), background).map_err(|error| {
        RuntimeError::Internal(format!("failed to write proxy auth service worker: {error}"))
    })?;

    log_info(
        "kernel",
        format!(
            "Prepared Supermium proxy authentication extension at {}",
            extension_dir.display()
        ),
    );
    Ok(Some(extension_dir.to_string_lossy().to_string()))
}

fn validate_browser_runtime_layout
'@
$launcher = Replace-RegexOnce $launcher `
  '\nfn validate_browser_runtime_layout' `
  $proxyAuthHelper `
  'Win7 Supermium authenticated proxy bridge'

$stopReplacement = @'
pub async fn stop_environment(
    env_uuid: String,
    cdp_endpoint_manager: Arc<CdpEndpointManager>,
    job_manager: Arc<JobManager>,
    status_manager: Arc<EnvironmentStatusManager>,
    events: EventPublisher,
) -> Result<()> {
    let env_id = env_uuid.trim().to_string();
    let manager = eventbus_manager();
    let eventbus_connected = manager.is_connected(&env_id).await;
    let has_cdp = cdp_endpoint_manager.get_port(&env_id).await.is_some();

    if !eventbus_connected && !has_cdp {
        return Err(RuntimeError::Internal(format!("环境 {} 未运行", env_id)));
    }

    status_manager
        .set_status(&env_id, EnvironmentStatus::Stopping)
        .await;

    if eventbus_connected {
        if let Err(error) = manager.disconnect(&env_id).await {
            log_warn(
                "kernel",
                format!(
                    "EventBus disconnect failed for environment {}, forcing process stop: {}",
                    env_id, error
                ),
            );
        }
    }

    // On Windows the JobHandle is configured with KILL_ON_JOB_CLOSE, so removing
    // the environment kills stock Supermium without requiring the patched EventBus.
    job_manager.remove(&env_id).await;
    cdp_endpoint_manager.remove(&env_id).await;
    status_manager
        .set_status(&env_id, EnvironmentStatus::Stopped)
        .await;
    let _ = events.emit(
        "environment.stopped",
        &serde_json::json!({ "env_uuid": env_id }),
    );
    Ok(())
}

pub async fn refresh_proxy
'@
$launcher = Replace-RegexOnce $launcher `
  'pub async fn stop_environment\(.*?\n\}\n\npub async fn refresh_proxy' `
  $stopReplacement `
  'Win7 Supermium EventBus-free stop path'

$refreshProxyReplacement = @'
pub async fn refresh_proxy(
    env_uuid: String,
    proxy: Option<super::types::BrowserProxyConfigPayload>,
    events: EventPublisher,
) -> Result<()> {
    let env_id = env_uuid.trim().to_string();
    let manager = eventbus_manager();

    if !manager.is_connected(&env_id).await {
        return Err(RuntimeError::Internal(
            "Supermium 代理在启动时通过 Chromium 参数应用；运行中热切换代理需要重启环境后生效"
                .into(),
        ));
    }

    let proxy_payload = match proxy {
        Some(proxy) => serde_json::to_vec(&proxy)
            .map_err(|error| RuntimeError::Serialization(error.to_string()))?,
        None => b"null".to_vec(),
    };

    manager.send_event(&env_id, Topic::ProxySet, proxy_payload).await?;
    let _ = events.emit(
        "environment.proxy_refreshed",
        &serde_json::json!({ "env_uuid": env_id }),
    );
    Ok(())
}

pub async fn set_window_bounds
'@
$launcher = Replace-RegexOnce $launcher `
  'pub async fn refresh_proxy\(.*?\n\}\n\npub async fn set_window_bounds' `
  $refreshProxyReplacement `
  'Win7 Supermium proxy refresh behavior'

$connectedReplacement = @'
pub async fn get_connected_environments(
    cdp_endpoint_manager: Arc<CdpEndpointManager>,
) -> Result<Vec<String>> {
    let mut env_ids = cdp_endpoint_manager.env_ids().await;
    if let Some(manager) = get_eventbus_manager() {
        for env_id in manager.connected_envs().await {
            if !env_ids.contains(&env_id) {
                env_ids.push(env_id);
            }
        }
    }
    env_ids.sort();
    env_ids.dedup();
    Ok(env_ids)
}

pub async fn get_cdp_endpoint
'@
$launcher = Replace-RegexOnce $launcher `
  'pub async fn get_connected_environments\(\) -> Result<Vec<String>> \{.*?\n\}\n\npub async fn get_cdp_endpoint' `
  $connectedReplacement `
  'Win7 Supermium connected-environment fallback'

$rpaReplacement = @'
async fn fetch_cdp_page_targets(
    env_id: &str,
    cdp_endpoint_manager: &CdpEndpointManager,
) -> Result<Vec<serde_json::Value>> {
    let endpoint = cdp_endpoint_manager
        .get_endpoint(env_id)
        .await
        .ok_or_else(|| RuntimeError::Internal(format!("环境 {} 没有可用的 CDP 端点", env_id)))?;
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .map_err(|error| RuntimeError::Internal(format!("failed to build CDP client: {error}")))?;
    let response = client
        .get(&endpoint.list_url)
        .send()
        .await
        .map_err(|error| RuntimeError::Internal(format!("failed to query CDP tab list: {error}")))?;
    if !response.status().is_success() {
        return Err(RuntimeError::Internal(format!(
            "CDP tab list returned HTTP {}",
            response.status()
        )));
    }
    let targets = response
        .json::<Vec<serde_json::Value>>()
        .await
        .map_err(|error| RuntimeError::Internal(format!("failed to decode CDP tab list: {error}")))?;
    Ok(targets
        .into_iter()
        .filter(|target| target.get("type").and_then(|value| value.as_str()) == Some("page"))
        .collect())
}

async fn invoke_cdp_target_action(
    env_id: &str,
    target_id: &str,
    action: &str,
    cdp_endpoint_manager: &CdpEndpointManager,
) -> Result<()> {
    let endpoint = cdp_endpoint_manager
        .get_endpoint(env_id)
        .await
        .ok_or_else(|| RuntimeError::Internal(format!("环境 {} 没有可用的 CDP 端点", env_id)))?;
    let url = format!(
        "http://{}:{}/json/{}/{}",
        endpoint.host, endpoint.port, action, target_id
    );
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .map_err(|error| RuntimeError::Internal(format!("failed to build CDP client: {error}")))?;
    let response = client
        .get(url)
        .send()
        .await
        .map_err(|error| RuntimeError::Internal(format!("CDP target action failed: {error}")))?;
    if !response.status().is_success() {
        return Err(RuntimeError::Internal(format!(
            "CDP target action {} returned HTTP {}",
            action,
            response.status()
        )));
    }
    Ok(())
}

pub async fn list_rpa_tabs(
    env_uuid: String,
    cdp_endpoint_manager: Arc<CdpEndpointManager>,
) -> Result<RpaTabsSnapshot> {
    let env_id = env_uuid.trim().to_string();
    let manager = eventbus_manager();

    if manager.is_connected(&env_id).await {
        let response = manager
            .send_request(
                &env_id,
                Topic::RpaCommand,
                encode_rpa_command("list_tabs", None)?,
            )
            .await?;
        return decode_rpa_response::<RpaTabsSnapshot>(response);
    }

    let targets = fetch_cdp_page_targets(&env_id, &cdp_endpoint_manager).await?;
    let tabs = targets
        .iter()
        .enumerate()
        .filter_map(|(position, target)| {
            let target_id = target.get("id")?.as_str()?.to_string();
            Some(RpaTabInfo {
                position: position as u32,
                title: target
                    .get("title")
                    .and_then(|value| value.as_str())
                    .unwrap_or_default()
                    .to_string(),
                url: target
                    .get("url")
                    .and_then(|value| value.as_str())
                    .unwrap_or_default()
                    .to_string(),
                active: false,
                target_id,
            })
        })
        .collect::<Vec<_>>();
    Ok(RpaTabsSnapshot {
        total: tabs.len() as u32,
        tabs,
        active_position: None,
    })
}

pub async fn select_rpa_tab(
    env_uuid: String,
    position: u32,
    cdp_endpoint_manager: Arc<CdpEndpointManager>,
) -> Result<RpaTabSelection> {
    let env_id = env_uuid.trim().to_string();
    let manager = eventbus_manager();

    if manager.is_connected(&env_id).await {
        let response = manager
            .send_request(
                &env_id,
                Topic::RpaCommand,
                encode_rpa_command("select_tab", Some(position))?,
            )
            .await?;
        return decode_rpa_response::<RpaTabSelection>(response);
    }

    let targets = fetch_cdp_page_targets(&env_id, &cdp_endpoint_manager).await?;
    let target = targets
        .get(position as usize)
        .ok_or_else(|| RuntimeError::Internal(format!("RPA tab position {} does not exist", position)))?;
    let target_id = target
        .get("id")
        .and_then(|value| value.as_str())
        .ok_or_else(|| RuntimeError::Internal("CDP target is missing id".into()))?
        .to_string();
    invoke_cdp_target_action(&env_id, &target_id, "activate", &cdp_endpoint_manager).await?;
    Ok(RpaTabSelection { position, target_id })
}

pub async fn close_rpa_tab(
    env_uuid: String,
    position: u32,
    cdp_endpoint_manager: Arc<CdpEndpointManager>,
) -> Result<RpaTabCloseResult> {
    let env_id = env_uuid.trim().to_string();
    let manager = eventbus_manager();

    if manager.is_connected(&env_id).await {
        let response = manager
            .send_request(
                &env_id,
                Topic::RpaCommand,
                encode_rpa_command("close_tab", Some(position))?,
            )
            .await?;
        return decode_rpa_response::<RpaTabCloseResult>(response);
    }

    let targets = fetch_cdp_page_targets(&env_id, &cdp_endpoint_manager).await?;
    let target = targets
        .get(position as usize)
        .ok_or_else(|| RuntimeError::Internal(format!("RPA tab position {} does not exist", position)))?;
    let target_id = target
        .get("id")
        .and_then(|value| value.as_str())
        .ok_or_else(|| RuntimeError::Internal("CDP target is missing id".into()))?
        .to_string();
    invoke_cdp_target_action(&env_id, &target_id, "close", &cdp_endpoint_manager).await?;
    tokio::time::sleep(Duration::from_millis(50)).await;
    let remaining = fetch_cdp_page_targets(&env_id, &cdp_endpoint_manager)
        .await
        .unwrap_or_default();
    let active_position = if remaining.is_empty() {
        0
    } else {
        (position as usize).min(remaining.len() - 1) as u32
    };
    Ok(RpaTabCloseResult {
        closed_position: position,
        active_position,
        target_id,
    })
}

pub async fn batch_launch_environments
'@
$launcher = Replace-RegexOnce $launcher `
  'pub async fn list_rpa_tabs\(env_uuid: String\) -> Result<RpaTabsSnapshot> \{.*?\n\}\n\npub async fn batch_launch_environments' `
  $rpaReplacement `
  'Win7 Supermium CDP-backed RPA fallback'

[IO.File]::WriteAllText($launcherPath, $launcher, $utf8NoBom)

$cdpPath = Join-Path $rootDir 'src-tauri/crates/runtime/src/services/environment/kernel/cdp.rs'
$cdp = [IO.File]::ReadAllText($cdpPath)
$cdpReplacement = @'
pub async fn clear_all(&self) {
        let mut ports = self.ports.write().await;
        ports.clear();
    }

    pub async fn env_ids(&self) -> Vec<String> {
        let ports = self.ports.read().await;
        ports.keys().cloned().collect()
    }

    pub async fn get_port
'@
$cdp = Replace-RegexOnce $cdp `
  'pub async fn clear_all\(&self\) \{\s*let mut ports = self\.ports\.write\(\)\.await;\s*ports\.clear\(\);\s*\}\s*\n\s*pub async fn get_port' `
  $cdpReplacement `
  'Win7 Supermium CDP environment registry'
[IO.File]::WriteAllText($cdpPath, $cdp, $utf8NoBom)

$kernelModPath = Join-Path $rootDir 'src-tauri/crates/runtime/src/services/environment/kernel/mod.rs'
$kernelMod = [IO.File]::ReadAllText($kernelModPath)
$kernelMod = Replace-RegexOnce $kernelMod `
  'let env_ids = get_connected_environments\(\)\.await\?;' `
  'let env_ids = get_connected_environments(self.cdp_endpoint_manager.clone()).await?;' `
  'Win7 Supermium connected environments call'
$kernelMod = Replace-RegexOnce $kernelMod `
  'let snapshot = list_rpa_tabs\(env_uuid\)\.await\?;' `
  'let snapshot = list_rpa_tabs(env_uuid, self.cdp_endpoint_manager.clone()).await?;' `
  'Win7 Supermium list RPA tabs call'
$kernelMod = Replace-RegexOnce $kernelMod `
  'let selection = select_rpa_tab\(env_uuid, position\)\.await\?;' `
  'let selection = select_rpa_tab(env_uuid, position, self.cdp_endpoint_manager.clone()).await?;' `
  'Win7 Supermium select RPA tab call'
$kernelMod = Replace-RegexOnce $kernelMod `
  'let result = close_rpa_tab\(env_uuid, position\)\.await\?;' `
  'let result = close_rpa_tab(env_uuid, position, self.cdp_endpoint_manager.clone()).await?;' `
  'Win7 Supermium close RPA tab call'
$kernelMod = Replace-RegexOnce $kernelMod `
  'pub async fn get_connected_env_count\(&self\) -> usize \{\s*match crate::infrastructure::eventbus::get_eventbus_manager\(\) \{\s*Some\(manager\) => manager\.connected_env_count\(\)\.await,\s*None => 0,\s*\}\s*\}' `
  'pub async fn get_connected_env_count(&self) -> usize { self.cdp_endpoint_manager.env_ids().await.len() }' `
  'Win7 Supermium connected count fallback'
[IO.File]::WriteAllText($kernelModPath, $kernelMod, $utf8NoBom)

Write-Host 'Applied Win7 Supermium runtime adapter: proxy args/auth, EventBus-free lifecycle, CDP RPA fallback.'
