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

$marker = 'Prepared Simprint environment status extension at {}'
if ($launcher.Contains($marker)) {
  Write-Host 'Win7 environment status diagnostics extension already applied.'
  exit 0
}

$extensionLoadAnchor = @'
    if !launch_extension_dirs.is_empty() {
'@
$extensionLoadReplacement = @'
    if let Some(status_dir) = prepare_environment_status_extension(
        user_data_dir,
        env_id,
        fingerprint_config,
        proxy,
    )? {
        launch_extension_dirs.push(status_dir);
    }

    if !launch_extension_dirs.is_empty() {
'@
$launcher = Replace-TextOnce $launcher $extensionLoadAnchor $extensionLoadReplacement 'Win7 environment status extension load hook'

$helperAnchor = @'
fn prepare_proxy_auth_extension(
'@
$helper = @'
fn stable_diagnostic_hash(bytes: &[u8]) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

fn prepare_environment_status_extension(
    user_data_dir: &str,
    env_id: &str,
    fingerprint_config: Option<&crate::infrastructure::eventbus::FingerprintConfig>,
    proxy: Option<&BrowserProxyConfigPayload>,
) -> Result<Option<String>> {
    let extension_dir = Path::new(user_data_dir).join("simprint_environment_status");
    std::fs::create_dir_all(&extension_dir).map_err(|error| {
        RuntimeError::Internal(format!(
            "failed to create environment status extension directory {}: {}",
            extension_dir.display(),
            error
        ))
    })?;

    let fingerprint_hash = fingerprint_config
        .and_then(|config| serde_json::to_vec(config).ok())
        .map(|bytes| stable_diagnostic_hash(&bytes))
        .unwrap_or_else(|| "none".to_string());
    let env_name = fingerprint_config
        .and_then(|config| config.env_name.as_deref())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(env_id);
    let display_id = fingerprint_config
        .and_then(|config| config.env_id.as_deref())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(env_id);
    let proxy_server = proxy
        .map(|config| config.server.trim())
        .filter(|value| !value.is_empty())
        .unwrap_or("DIRECT");

    let capabilities = SupermiumAdapter::capabilities();
    let unsupported = capabilities
        .iter()
        .filter(|item| {
            matches!(
                item.capability,
                super::adapter::FingerprintCapability::Unsupported
            )
        })
        .map(|item| item.name)
        .collect::<Vec<_>>();
    let supported_count = capabilities.len().saturating_sub(unsupported.len());

    let metadata = serde_json::json!({
        "envId": env_id,
        "displayId": display_id,
        "envName": env_name,
        "proxyServer": proxy_server,
        "fingerprintHash": fingerprint_hash,
        "supportedCapabilityCount": supported_count,
        "capabilityCount": capabilities.len(),
        "unsupportedCapabilities": unsupported,
    });
    let metadata_json = serde_json::to_string(&metadata).map_err(|error| {
        RuntimeError::Internal(format!("failed to encode environment status metadata: {error}"))
    })?;

    let manifest = serde_json::json!({
        "manifest_version": 3,
        "name": "Simprint Environment Status",
        "version": "1.0.0",
        "description": "Local environment, egress and fingerprint diagnostics for Simprint.",
        "permissions": ["storage", "tabs"],
        "host_permissions": [
            "https://realip.cc/*",
            "https://api.ip.sb/*",
            "https://ipapi.co/*"
        ],
        "background": { "service_worker": "background.js" },
        "action": {
            "default_title": "Simprint Environment Status",
            "default_popup": "popup.html"
        },
        "content_scripts": [{
            "matches": ["http://*/*", "https://*/*"],
            "js": ["content.js"],
            "run_at": "document_start"
        }]
    });
    let manifest_bytes = serde_json::to_vec_pretty(&manifest).map_err(|error| {
        RuntimeError::Internal(format!("failed to serialize environment status manifest: {error}"))
    })?;
    std::fs::write(extension_dir.join("manifest.json"), manifest_bytes).map_err(|error| {
        RuntimeError::Internal(format!("failed to write environment status manifest: {error}"))
    })?;

    let background = r####"const META = __SIMPRINT_STATUS_METADATA__;
let cachedNetwork = null;
let cachedAt = 0;
const CACHE_MS = 30000;

function normalizeString(value) {
  return typeof value === 'string' ? value.trim() : '';
}

async function fetchJson(url, timeoutMs = 6000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const startedAt = performance.now();
  try {
    const response = await fetch(url, {
      cache: 'no-store',
      credentials: 'omit',
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const payload = await response.json();
    return { payload, latencyMs: Math.max(0, Math.round(performance.now() - startedAt)) };
  } finally {
    clearTimeout(timer);
  }
}

async function probeNetwork() {
  const sources = [
    {
      url: 'https://realip.cc/',
      map: (value) => ({
        ip: normalizeString(value.ip),
        country: normalizeString(value.country),
        countryCode: normalizeString(value.iso_code),
        city: normalizeString(value.city),
      }),
    },
    {
      url: 'https://api.ip.sb/geoip/',
      map: (value) => ({
        ip: normalizeString(value.ip),
        country: normalizeString(value.country),
        countryCode: normalizeString(value.country_code),
        city: normalizeString(value.city),
      }),
    },
    {
      url: 'https://ipapi.co/json/',
      map: (value) => ({
        ip: normalizeString(value.ip),
        country: normalizeString(value.country_name),
        countryCode: normalizeString(value.country_code),
        city: normalizeString(value.city),
      }),
    },
  ];

  let lastError = 'IP check failed';
  for (const source of sources) {
    try {
      const { payload, latencyMs } = await fetchJson(source.url);
      const mapped = source.map(payload || {});
      if (!mapped.ip) throw new Error('missing IP');
      return {
        ok: true,
        ...mapped,
        latencyMs,
        checkedAt: Date.now(),
      };
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
    }
  }

  return {
    ok: false,
    ip: '',
    country: '',
    countryCode: '',
    city: '',
    latencyMs: null,
    error: lastError,
    checkedAt: Date.now(),
  };
}

async function updateBadge(network) {
  const text = network.ok ? (network.countryCode || 'OK').slice(0, 4).toUpperCase() : '!';
  await chrome.action.setBadgeText({ text });
  await chrome.action.setBadgeBackgroundColor({ color: network.ok ? '#16803a' : '#b42318' });
  const location = [network.countryCode, network.city].filter(Boolean).join(' ');
  const detail = network.ok
    ? `${network.ip}${location ? ` | ${location}` : ''} | ${network.latencyMs}ms`
    : `Proxy/IP check failed: ${network.error || 'unknown error'}`;
  await chrome.action.setTitle({ title: `${META.envName} | ${detail}` });
}

async function getStatus(force) {
  const now = Date.now();
  if (force || !cachedNetwork || now - cachedAt > CACHE_MS) {
    cachedNetwork = await probeNetwork();
    cachedAt = now;
    await updateBadge(cachedNetwork);
  }
  return { meta: META, network: cachedNetwork };
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || message.type !== 'simprint_status_get') return false;
  getStatus(Boolean(message.force))
    .then((status) => sendResponse({ ok: true, status }))
    .catch((error) => sendResponse({ ok: false, error: String(error) }));
  return true;
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.storage.local.get({ showPageBar: false }, (state) => {
    chrome.storage.local.set({ showPageBar: Boolean(state.showPageBar) });
  });
  void getStatus(true);
});

chrome.runtime.onStartup.addListener(() => {
  void getStatus(true);
});

void getStatus(false);
"####.replace("__SIMPRINT_STATUS_METADATA__", &metadata_json);
    std::fs::write(extension_dir.join("background.js"), background).map_err(|error| {
        RuntimeError::Internal(format!("failed to write environment status background script: {error}"))
    })?;

    let content = r####"let simprintStatusHost = null;

function fnv1a(input) {
  let hash = 0x811c9dc5;
  for (let index = 0; index < input.length; index += 1) {
    hash ^= input.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, '0');
}

function collectRuntimeSnapshot() {
  let canvasSample = '';
  let webglVendor = '';
  let webglRenderer = '';
  try {
    const canvas = document.createElement('canvas');
    canvas.width = 240;
    canvas.height = 40;
    const ctx = canvas.getContext('2d');
    if (ctx) {
      ctx.textBaseline = 'top';
      ctx.font = '14px Arial';
      ctx.fillText('Simprint fingerprint diagnostic 0123456789', 2, 2);
      canvasSample = canvas.toDataURL().slice(-256);
    }
    const gl = canvas.getContext('webgl') || canvas.getContext('experimental-webgl');
    if (gl) {
      const ext = gl.getExtension('WEBGL_debug_renderer_info');
      if (ext) {
        webglVendor = String(gl.getParameter(ext.UNMASKED_VENDOR_WEBGL) || '');
        webglRenderer = String(gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) || '');
      }
    }
  } catch (_) {}

  const snapshot = {
    userAgent: navigator.userAgent || '',
    platform: navigator.platform || '',
    language: navigator.language || '',
    languages: Array.from(navigator.languages || []),
    hardwareConcurrency: navigator.hardwareConcurrency || 0,
    deviceMemory: navigator.deviceMemory || 0,
    maxTouchPoints: navigator.maxTouchPoints || 0,
    timezone: (() => {
      try { return Intl.DateTimeFormat().resolvedOptions().timeZone || ''; } catch (_) { return ''; }
    })(),
    screen: `${screen.width}x${screen.height}x${screen.colorDepth}`,
    devicePixelRatio: window.devicePixelRatio || 1,
    webglVendor,
    webglRenderer,
    canvasSample,
  };
  return {
    hash: fnv1a(JSON.stringify(snapshot)),
    summary: snapshot,
  };
}

function removePageBar() {
  if (simprintStatusHost && simprintStatusHost.isConnected) simprintStatusHost.remove();
  simprintStatusHost = null;
}

function locationText(network) {
  return [network.countryCode, network.city].filter(Boolean).join(' ');
}

async function showPageBar() {
  removePageBar();
  if (!document.documentElement) return;

  const response = await chrome.runtime.sendMessage({ type: 'simprint_status_get', force: false }).catch(() => null);
  if (!response || !response.ok) return;

  const { meta, network } = response.status;
  const runtime = collectRuntimeSnapshot();
  const host = document.createElement('div');
  host.style.cssText = 'all:initial;position:fixed;left:0;right:0;top:0;height:28px;z-index:2147483647;pointer-events:auto;';
  const shadow = host.attachShadow({ mode: 'closed' });
  const wrapper = document.createElement('div');
  wrapper.style.cssText = 'box-sizing:border-box;height:28px;display:flex;align-items:center;justify-content:center;gap:14px;padding:0 12px;background:#f8fafc;border-bottom:1px solid #cbd5e1;color:#0f172a;font:12px/1.2 Arial,sans-serif;box-shadow:0 1px 3px rgba(15,23,42,.12);white-space:nowrap;overflow:hidden;';
  const state = network.ok ? '●' : '●';
  const stateColor = network.ok ? '#16803a' : '#b42318';
  const networkText = network.ok
    ? `${network.ip} ${locationText(network)} ${network.latencyMs}ms`
    : `IP check failed`;
  wrapper.innerHTML = `<span style="color:${stateColor}">${state}</span><strong></strong><span></span><span></span><span></span><button type="button" style="margin-left:auto;border:0;background:transparent;cursor:pointer;font:16px Arial;color:#64748b;padding:0 4px" title="Hide Simprint status bar">×</button>`;
  const nodes = wrapper.querySelectorAll('span');
  wrapper.querySelector('strong').textContent = meta.envName || meta.displayId || 'Simprint';
  nodes[1].textContent = networkText;
  nodes[2].textContent = `FP ${meta.fingerprintHash} / JS ${runtime.hash}`;
  nodes[3].textContent = meta.proxyServer || 'DIRECT';
  wrapper.querySelector('button').addEventListener('click', () => {
    chrome.storage.local.set({ showPageBar: false });
    removePageBar();
  });
  shadow.appendChild(wrapper);
  document.documentElement.appendChild(host);
  simprintStatusHost = host;
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message) return false;
  if (message.type === 'simprint_runtime_snapshot') {
    sendResponse({ ok: true, runtime: collectRuntimeSnapshot() });
    return false;
  }
  if (message.type === 'simprint_page_bar') {
    if (message.show) void showPageBar(); else removePageBar();
    sendResponse({ ok: true });
    return false;
  }
  return false;
});

chrome.storage.local.get({ showPageBar: false }, (state) => {
  if (state.showPageBar) {
    const run = () => void showPageBar();
    if (document.documentElement) run(); else document.addEventListener('DOMContentLoaded', run, { once: true });
  }
});
"####;
    std::fs::write(extension_dir.join("content.js"), content).map_err(|error| {
        RuntimeError::Internal(format!("failed to write environment status content script: {error}"))
    })?;

    let popup_html = r####"<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
body{margin:0;width:390px;background:#fff;color:#0f172a;font:13px Arial,sans-serif}main{padding:14px}.title{display:flex;align-items:center;justify-content:space-between;margin-bottom:12px}.title strong{font-size:15px}.grid{display:grid;grid-template-columns:92px 1fr;gap:8px 10px;align-items:start}.label{color:#64748b}.value{word-break:break-all}.ok{color:#16803a}.bad{color:#b42318}.muted{color:#64748b}.footer{display:flex;align-items:center;justify-content:space-between;border-top:1px solid #e2e8f0;margin-top:12px;padding-top:10px}button{border:1px solid #cbd5e1;background:#fff;border-radius:5px;padding:5px 9px;cursor:pointer}#unsupported{max-height:72px;overflow:auto}
</style>
</head>
<body><main>
<div class="title"><strong id="envName">Simprint</strong><span id="state" class="muted">checking…</span></div>
<div class="grid">
<div class="label">出口 IP</div><div class="value" id="ip">—</div>
<div class="label">位置</div><div class="value" id="location">—</div>
<div class="label">延迟</div><div class="value" id="latency">—</div>
<div class="label">代理链</div><div class="value" id="proxy">—</div>
<div class="label">配置指纹</div><div class="value" id="fp">—</div>
<div class="label">运行时指纹</div><div class="value" id="runtimeFp">—</div>
<div class="label">能力覆盖</div><div class="value" id="capabilities">—</div>
<div class="label">深层未覆盖</div><div class="value bad" id="unsupported">—</div>
</div>
<div class="footer"><label><input id="showBar" type="checkbox"> 页面顶部状态条</label><button id="refresh" type="button">刷新</button></div>
</main><script src="popup.js"></script></body>
</html>"####;
    std::fs::write(extension_dir.join("popup.html"), popup_html).map_err(|error| {
        RuntimeError::Internal(format!("failed to write environment status popup: {error}"))
    })?;

    let popup_js = r####"function setText(id, value) {
  const element = document.getElementById(id);
  if (element) element.textContent = value || '—';
}

async function getRuntimeSnapshot() {
  try {
    const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
    const tab = tabs[0];
    if (!tab || typeof tab.id !== 'number') return null;
    const response = await chrome.tabs.sendMessage(tab.id, { type: 'simprint_runtime_snapshot' });
    return response && response.ok ? response.runtime : null;
  } catch (_) {
    return null;
  }
}

async function render(force) {
  const state = document.getElementById('state');
  state.textContent = 'checking…';
  state.className = 'muted';
  try {
    const response = await chrome.runtime.sendMessage({ type: 'simprint_status_get', force: Boolean(force) });
    if (!response || !response.ok) throw new Error(response && response.error ? response.error : 'status unavailable');
    const { meta, network } = response.status;
    const runtime = await getRuntimeSnapshot();
    setText('envName', meta.envName || meta.displayId || 'Simprint');
    setText('ip', network.ip);
    setText('location', [network.countryCode, network.country, network.city].filter(Boolean).join(' · '));
    setText('latency', network.ok && network.latencyMs != null ? `${network.latencyMs} ms` : '—');
    setText('proxy', meta.proxyServer || 'DIRECT');
    setText('fp', meta.fingerprintHash || 'none');
    setText('runtimeFp', runtime ? runtime.hash : '当前页面不可检测');
    setText('capabilities', `${meta.supportedCapabilityCount}/${meta.capabilityCount}`);
    setText('unsupported', Array.isArray(meta.unsupportedCapabilities) && meta.unsupportedCapabilities.length
      ? meta.unsupportedCapabilities.join(', ')
      : 'none');
    state.textContent = network.ok ? 'proxy online' : 'proxy check failed';
    state.className = network.ok ? 'ok' : 'bad';
  } catch (error) {
    state.textContent = 'status error';
    state.className = 'bad';
    setText('ip', String(error));
  }
}

async function broadcastBar(show) {
  const tabs = await chrome.tabs.query({});
  await Promise.all(tabs.map(async (tab) => {
    if (typeof tab.id !== 'number') return;
    try { await chrome.tabs.sendMessage(tab.id, { type: 'simprint_page_bar', show }); } catch (_) {}
  }));
}

document.addEventListener('DOMContentLoaded', async () => {
  const showBar = document.getElementById('showBar');
  const stored = await chrome.storage.local.get({ showPageBar: false });
  showBar.checked = Boolean(stored.showPageBar);
  showBar.addEventListener('change', async () => {
    const show = Boolean(showBar.checked);
    await chrome.storage.local.set({ showPageBar: show });
    await broadcastBar(show);
  });
  document.getElementById('refresh').addEventListener('click', () => void render(true));
  await render(false);
});
"####;
    std::fs::write(extension_dir.join("popup.js"), popup_js).map_err(|error| {
        RuntimeError::Internal(format!("failed to write environment status popup script: {error}"))
    })?;

    log_info(
        "kernel",
        format!(
            "Prepared Simprint environment status extension at {}",
            extension_dir.display()
        ),
    );
    Ok(Some(extension_dir.to_string_lossy().to_string()))
}

fn prepare_proxy_auth_extension(
'@
$launcher = Replace-TextOnce $launcher $helperAnchor $helper 'Win7 environment status extension helper'

if (-not $launcher.Contains($marker)) {
  throw 'Win7 environment status diagnostics extension patch was not applied'
}

[IO.File]::WriteAllText($launcherPath, $launcher, $utf8NoBom)
Write-Host 'Applied Win7 environment diagnostics: native extension badge/popup plus opt-in page status bar.'
