use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Duration;

use once_cell::sync::Lazy;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;
use tokio::task::{JoinHandle, JoinSet};
use tokio_socks::TargetAddr;
use tokio_socks::tcp::Socks5Stream;

use crate::core::error::Result;
use crate::services::environment::ProxyConfig;

const UPSTREAM_CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const MAX_HTTP_HEADER_BYTES: usize = 64 * 1024;

#[derive(Clone)]
struct Socks5Upstream {
    host: String,
    port: u16,
    username: Option<String>,
    password: Option<String>,
}

struct ProxyBridgeHandle {
    task: JoinHandle<()>,
}

struct ResolvedHttpTarget {
    target: TargetAddr<'static>,
    origin_form: String,
    authority: String,
}

static PROXY_BRIDGES: Lazy<Mutex<HashMap<String, ProxyBridgeHandle>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

pub async fn prepare_browser_proxy(
    env_uuid: &str,
    proxy: Option<ProxyConfig>,
) -> Result<Option<ProxyConfig>> {
    let Some(proxy) = proxy else {
        stop_proxy_bridge(env_uuid).await;
        return Ok(None);
    };

    if !proxy.proxy_type.eq_ignore_ascii_case("socks5") {
        stop_proxy_bridge(env_uuid).await;
        return Ok(Some(proxy));
    }

    let username = proxy
        .username
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let password = proxy
        .password
        .as_ref()
        .map(|value| value.value.as_str())
        .filter(|value| !value.is_empty());

    if username.is_some() != password.is_some() {
        return Err(
            "SOCKS5 代理认证信息不完整：用户名和密码必须同时填写；已阻止错误代理启动".into(),
        );
    }

    let upstream = Socks5Upstream {
        host: normalize_connect_host(&proxy.host),
        port: proxy.port,
        username: username.map(ToOwned::to_owned),
        password: password.map(ToOwned::to_owned),
    };
    let local_port = start_proxy_bridge(env_uuid, upstream.clone()).await?;

    // Chromium/Supermium only talks to a simple localhost HTTP proxy. The
    // bridge owns SOCKS5 negotiation, authentication and remote DNS. This is
    // the same browser-facing shape as the proven Mihomo local-proxy path and
    // avoids Chromium's SOCKS implementation/auth limitations on Win7.
    log::info!(
        "SOCKS5 -> HTTP proxy bridge ready for env_uuid={} on 127.0.0.1:{} upstream={}:{} auth={}",
        env_uuid,
        local_port,
        upstream.host,
        upstream.port,
        upstream.username.is_some()
    );

    Ok(Some(ProxyConfig {
        host: "127.0.0.1".to_string(),
        port: local_port,
        proxy_type: "http".to_string(),
        username: None,
        password: None,
    }))
}

pub async fn stop_proxy_bridge(env_uuid: &str) {
    if let Some(handle) = PROXY_BRIDGES.lock().await.remove(env_uuid) {
        handle.task.abort();
        log::debug!("Stopped SOCKS5/HTTP proxy bridge for env_uuid={}", env_uuid);
    }
}

async fn start_proxy_bridge(env_uuid: &str, upstream: Socks5Upstream) -> Result<u16> {
    stop_proxy_bridge(env_uuid).await;

    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .await
        .map_err(|error| format!("无法创建本地 SOCKS5/HTTP 代理桥: {error}"))?;
    let local_port = listener
        .local_addr()
        .map_err(|error| format!("无法读取本地 SOCKS5/HTTP 代理桥端口: {error}"))?
        .port();
    let env_id = env_uuid.to_string();

    let task = tokio::spawn(async move {
        let mut connections = JoinSet::new();
        loop {
            tokio::select! {
                accepted = listener.accept() => {
                    match accepted {
                        Ok((stream, _)) => {
                            let connection_upstream = upstream.clone();
                            let connection_env_id = env_id.clone();
                            connections.spawn(async move {
                                if let Err(error) = handle_http_proxy_client(stream, connection_upstream).await {
                                    log::warn!(
                                        "SOCKS5/HTTP proxy bridge connection failed for env_uuid={}: {}",
                                        connection_env_id,
                                        error
                                    );
                                }
                            });
                        }
                        Err(error) => {
                            log::warn!(
                                "SOCKS5/HTTP proxy bridge listener stopped for env_uuid={}: {}",
                                env_id,
                                error
                            );
                            break;
                        }
                    }
                }
                completed = connections.join_next(), if !connections.is_empty() => {
                    if let Some(Err(error)) = completed {
                        log::warn!(
                            "SOCKS5/HTTP proxy bridge task failed for env_uuid={}: {}",
                            env_id,
                            error
                        );
                    }
                }
            }
        }
    });

    PROXY_BRIDGES
        .lock()
        .await
        .insert(env_uuid.to_string(), ProxyBridgeHandle { task });

    Ok(local_port)
}

async fn handle_http_proxy_client(
    mut client: TcpStream,
    upstream: Socks5Upstream,
) -> std::result::Result<(), String> {
    let (request, header_end) = read_http_request_head(&mut client).await?;
    let buffered_body = request[header_end..].to_vec();
    let header_text = String::from_utf8_lossy(&request[..header_end - 4]).into_owned();
    let mut lines = header_text.split("\r\n");
    let request_line = lines.next().ok_or_else(|| "HTTP 代理请求缺少请求行".to_string())?;
    let mut request_parts = request_line.split_whitespace();
    let method = request_parts
        .next()
        .ok_or_else(|| "HTTP 代理请求缺少方法".to_string())?;
    let request_target = request_parts
        .next()
        .ok_or_else(|| "HTTP 代理请求缺少目标".to_string())?;
    let version = request_parts
        .next()
        .ok_or_else(|| "HTTP 代理请求缺少协议版本".to_string())?;
    if request_parts.next().is_some() {
        let _ = write_http_error(&mut client, 400, "Bad Request").await;
        return Err("HTTP 代理请求行格式无效".to_string());
    }

    let headers = lines.map(ToOwned::to_owned).collect::<Vec<_>>();

    if method.eq_ignore_ascii_case("CONNECT") {
        let (host, port) = parse_authority(request_target, 443)?;
        let target = to_target_addr(&host, port);
        let mut remote = match connect_upstream(&upstream, target).await {
            Ok(stream) => stream,
            Err(error) => {
                let _ = write_http_error(&mut client, 502, "Bad Gateway").await;
                return Err(error);
            }
        };

        client
            .write_all(b"HTTP/1.1 200 Connection Established\r\nProxy-Agent: Simprint\r\n\r\n")
            .await
            .map_err(|error| format!("写入 HTTP CONNECT 响应失败: {error}"))?;
        if !buffered_body.is_empty() {
            remote
                .write_all(&buffered_body)
                .await
                .map_err(|error| format!("转发 CONNECT 预读数据失败: {error}"))?;
        }
        tokio::io::copy_bidirectional(&mut client, &mut remote)
            .await
            .map_err(|error| format!("SOCKS5/HTTP CONNECT 双向转发失败: {error}"))?;
        return Ok(());
    }

    let resolved = resolve_http_target(request_target, &headers)?;
    let mut remote = match connect_upstream(&upstream, resolved.target).await {
        Ok(stream) => stream,
        Err(error) => {
            let _ = write_http_error(&mut client, 502, "Bad Gateway").await;
            return Err(error);
        }
    };

    let rewritten = rewrite_http_request(
        method,
        &resolved.origin_form,
        version,
        &headers,
        &resolved.authority,
    );
    remote
        .write_all(rewritten.as_bytes())
        .await
        .map_err(|error| format!("转发 HTTP 代理请求头失败: {error}"))?;
    if !buffered_body.is_empty() {
        remote
            .write_all(&buffered_body)
            .await
            .map_err(|error| format!("转发 HTTP 代理请求体失败: {error}"))?;
    }

    tokio::io::copy_bidirectional(&mut client, &mut remote)
        .await
        .map_err(|error| format!("SOCKS5/HTTP 双向转发失败: {error}"))?;
    Ok(())
}

async fn read_http_request_head(
    client: &mut TcpStream,
) -> std::result::Result<(Vec<u8>, usize), String> {
    let mut buffer = Vec::with_capacity(4096);
    let mut chunk = [0_u8; 4096];

    loop {
        let read = client
            .read(&mut chunk)
            .await
            .map_err(|error| format!("读取 HTTP 代理请求失败: {error}"))?;
        if read == 0 {
            return Err("HTTP 代理连接在请求头完成前关闭".to_string());
        }
        buffer.extend_from_slice(&chunk[..read]);
        if let Some(end) = find_header_end(&buffer) {
            return Ok((buffer, end));
        }
        if buffer.len() > MAX_HTTP_HEADER_BYTES {
            return Err(format!(
                "HTTP 代理请求头超过 {} 字节限制",
                MAX_HTTP_HEADER_BYTES
            ));
        }
    }
}

fn find_header_end(buffer: &[u8]) -> Option<usize> {
    buffer
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|position| position + 4)
}

fn resolve_http_target(
    request_target: &str,
    headers: &[String],
) -> std::result::Result<ResolvedHttpTarget, String> {
    if let Some(rest) = strip_prefix_ascii_case(request_target, "http://") {
        let (authority, origin_form) = split_absolute_http_target(rest)?;
        let (host, port) = parse_authority(&authority, 80)?;
        return Ok(ResolvedHttpTarget {
            target: to_target_addr(&host, port),
            origin_form,
            authority,
        });
    }

    if strip_prefix_ascii_case(request_target, "https://").is_some() {
        return Err("HTTPS 代理请求必须使用 CONNECT".to_string());
    }

    let authority = find_header_value(headers, "host")
        .ok_or_else(|| "HTTP 代理请求缺少 Host 头".to_string())?
        .to_string();
    let (host, port) = parse_authority(&authority, 80)?;
    Ok(ResolvedHttpTarget {
        target: to_target_addr(&host, port),
        origin_form: request_target.to_string(),
        authority,
    })
}

fn split_absolute_http_target(rest: &str) -> std::result::Result<(String, String), String> {
    let boundary = rest.find(|character| character == '/' || character == '?');
    let (authority, origin_form) = match boundary {
        Some(index) => {
            let authority = &rest[..index];
            let suffix = &rest[index..];
            let origin = if suffix.starts_with('?') {
                format!("/{suffix}")
            } else {
                suffix.to_string()
            };
            (authority, origin)
        }
        None => (rest, "/".to_string()),
    };

    if authority.trim().is_empty() {
        return Err("HTTP 代理绝对 URL 缺少主机".to_string());
    }
    Ok((authority.to_string(), origin_form))
}

fn find_header_value<'a>(headers: &'a [String], name: &str) -> Option<&'a str> {
    headers.iter().find_map(|header| {
        let (header_name, value) = header.split_once(':')?;
        header_name.eq_ignore_ascii_case(name).then(|| value.trim())
    })
}

fn rewrite_http_request(
    method: &str,
    origin_form: &str,
    version: &str,
    headers: &[String],
    authority: &str,
) -> String {
    let mut output = format!("{method} {origin_form} {version}\r\n");
    let mut has_host = false;

    for header in headers {
        let Some((name, _)) = header.split_once(':') else {
            continue;
        };
        if name.eq_ignore_ascii_case("proxy-connection")
            || name.eq_ignore_ascii_case("proxy-authorization")
        {
            continue;
        }
        if name.eq_ignore_ascii_case("host") {
            has_host = true;
        }
        output.push_str(header);
        output.push_str("\r\n");
    }

    if !has_host {
        output.push_str("Host: ");
        output.push_str(authority);
        output.push_str("\r\n");
    }
    output.push_str("\r\n");
    output
}

fn parse_authority(authority: &str, default_port: u16) -> std::result::Result<(String, u16), String> {
    let value = authority.trim();
    if value.is_empty() {
        return Err("代理目标地址为空".to_string());
    }

    if let Some(rest) = value.strip_prefix('[') {
        let closing = rest
            .find(']')
            .ok_or_else(|| format!("IPv6 代理目标缺少 ]: {value}"))?;
        let host = &rest[..closing];
        let suffix = &rest[closing + 1..];
        let port = if suffix.is_empty() {
            default_port
        } else {
            let raw_port = suffix
                .strip_prefix(':')
                .ok_or_else(|| format!("IPv6 代理目标端口格式无效: {value}"))?;
            parse_port(raw_port, value)?
        };
        return Ok((host.to_string(), port));
    }

    if value.parse::<IpAddr>().is_ok() {
        return Ok((value.to_string(), default_port));
    }

    if let Some((host, raw_port)) = value.rsplit_once(':') {
        if !host.is_empty() && !raw_port.is_empty() && raw_port.bytes().all(|byte| byte.is_ascii_digit()) {
            return Ok((host.to_string(), parse_port(raw_port, value)?));
        }
    }

    Ok((value.to_string(), default_port))
}

fn parse_port(raw_port: &str, authority: &str) -> std::result::Result<u16, String> {
    raw_port
        .parse::<u16>()
        .map_err(|_| format!("代理目标端口无效: {authority}"))
}

fn to_target_addr(host: &str, port: u16) -> TargetAddr<'static> {
    match host.parse::<IpAddr>() {
        Ok(address) => TargetAddr::Ip(SocketAddr::new(address, port)),
        Err(_) => TargetAddr::Domain(host.to_string().into(), port),
    }
}

async fn connect_upstream(
    upstream: &Socks5Upstream,
    target: TargetAddr<'static>,
) -> std::result::Result<Socks5Stream<TcpStream>, String> {
    let proxy_addr = (upstream.host.as_str(), upstream.port);

    if let (Some(username), Some(password)) = (&upstream.username, &upstream.password) {
        match tokio::time::timeout(
            UPSTREAM_CONNECT_TIMEOUT,
            Socks5Stream::connect_with_password(proxy_addr, target, username, password),
        )
        .await
        {
            Ok(Ok(stream)) => Ok(stream),
            Ok(Err(error)) => Err(format!(
                "上游 SOCKS5 认证/连接失败 {}:{}: {error}",
                upstream.host, upstream.port
            )),
            Err(_) => Err(format!(
                "上游 SOCKS5 连接超时 {}:{}",
                upstream.host, upstream.port
            )),
        }
    } else {
        match tokio::time::timeout(
            UPSTREAM_CONNECT_TIMEOUT,
            Socks5Stream::connect(proxy_addr, target),
        )
        .await
        {
            Ok(Ok(stream)) => Ok(stream),
            Ok(Err(error)) => Err(format!(
                "上游 SOCKS5 连接失败 {}:{}: {error}",
                upstream.host, upstream.port
            )),
            Err(_) => Err(format!(
                "上游 SOCKS5 连接超时 {}:{}",
                upstream.host, upstream.port
            )),
        }
    }
}

async fn write_http_error(
    client: &mut TcpStream,
    status: u16,
    reason: &str,
) -> std::result::Result<(), String> {
    let body = format!("Simprint proxy bridge: {status} {reason}\n");
    let response = format!(
        "HTTP/1.1 {status} {reason}\r\nConnection: close\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\n\r\n{}",
        body.len(),
        body
    );
    client
        .write_all(response.as_bytes())
        .await
        .map_err(|error| format!("写入 HTTP 代理错误响应失败: {error}"))
}

fn strip_prefix_ascii_case<'a>(value: &'a str, prefix: &str) -> Option<&'a str> {
    let head = value.get(..prefix.len())?;
    head.eq_ignore_ascii_case(prefix)
        .then(|| &value[prefix.len()..])
}

fn normalize_connect_host(host: &str) -> String {
    let host = host.trim();
    host.strip_prefix('[')
        .and_then(|value| value.strip_suffix(']'))
        .unwrap_or(host)
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::{parse_authority, resolve_http_target, rewrite_http_request};

    #[test]
    fn parses_ipv6_authority_with_port() {
        assert_eq!(
            parse_authority("[2001:db8::1]:443", 80).unwrap(),
            ("2001:db8::1".to_string(), 443)
        );
        assert_eq!(
            parse_authority("2001:db8::1", 1080).unwrap(),
            ("2001:db8::1".to_string(), 1080)
        );
    }

    #[test]
    fn resolves_absolute_http_proxy_target_without_local_dns() {
        let headers = vec!["User-Agent: test".to_string()];
        let resolved = resolve_http_target("http://example.com/path?q=1", &headers).unwrap();
        assert_eq!(resolved.authority, "example.com");
        assert_eq!(resolved.origin_form, "/path?q=1");
    }

    #[test]
    fn strips_proxy_only_headers_when_forwarding_plain_http() {
        let headers = vec![
            "Host: example.com".to_string(),
            "Proxy-Connection: keep-alive".to_string(),
            "Proxy-Authorization: Basic secret".to_string(),
            "Accept: */*".to_string(),
        ];
        let request = rewrite_http_request("GET", "/", "HTTP/1.1", &headers, "example.com");
        assert!(request.starts_with("GET / HTTP/1.1\r\n"));
        assert!(request.contains("Host: example.com\r\n"));
        assert!(request.contains("Accept: */*\r\n"));
        assert!(!request.contains("Proxy-Connection"));
        assert!(!request.contains("Proxy-Authorization"));
    }
}
