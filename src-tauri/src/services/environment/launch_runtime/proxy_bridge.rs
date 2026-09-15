use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
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

const UPSTREAM_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone)]
struct AuthenticatedSocks5Proxy {
    host: String,
    port: u16,
    username: String,
    password: String,
}

struct ProxyBridgeHandle {
    task: JoinHandle<()>,
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

    let username = proxy.username.as_deref().map(str::trim).filter(|value| !value.is_empty());
    let password = proxy
        .password
        .as_ref()
        .map(|value| value.value.as_str())
        .filter(|value| !value.is_empty());

    match (username, password) {
        (None, None) => {
            stop_proxy_bridge(env_uuid).await;
            Ok(Some(proxy))
        }
        (Some(_), None) | (None, Some(_)) => Err(
            "SOCKS5 代理认证信息不完整：用户名和密码必须同时填写；已阻止错误代理启动".into(),
        ),
        (Some(username), Some(password)) => {
            let upstream = AuthenticatedSocks5Proxy {
                host: normalize_connect_host(&proxy.host),
                port: proxy.port,
                username: username.to_string(),
                password: password.to_string(),
            };

            preflight_upstream(&upstream).await?;
            let local_port = start_proxy_bridge(env_uuid, upstream).await?;

            log::info!(
                "SOCKS5 authenticated proxy bridge ready for env_uuid={} on 127.0.0.1:{}",
                env_uuid,
                local_port
            );

            Ok(Some(ProxyConfig {
                host: "127.0.0.1".to_string(),
                port: local_port,
                proxy_type: "socks5".to_string(),
                username: None,
                password: None,
            }))
        }
    }
}

pub async fn stop_proxy_bridge(env_uuid: &str) {
    if let Some(handle) = PROXY_BRIDGES.lock().await.remove(env_uuid) {
        handle.task.abort();
        log::debug!("Stopped SOCKS5 proxy bridge for env_uuid={}", env_uuid);
    }
}

async fn preflight_upstream(proxy: &AuthenticatedSocks5Proxy) -> Result<()> {
    let connect = TcpStream::connect((proxy.host.as_str(), proxy.port));
    match tokio::time::timeout(UPSTREAM_CONNECT_TIMEOUT, connect).await {
        Ok(Ok(stream)) => {
            drop(stream);
            Ok(())
        }
        Ok(Err(error)) => Err(format!(
            "SOCKS5 代理服务器无法从本机访问 {}:{}: {}。如果这是 IPv6 代理，请确认 Win7 主机具备可用 IPv6 路由。",
            proxy.host, proxy.port, error
        )
        .into()),
        Err(_) => Err(format!(
            "SOCKS5 代理服务器连接超时 {}:{}。已阻止启动，避免浏览器只显示 ERR_SOCKS_CONNECTION_FAILED。",
            proxy.host, proxy.port
        )
        .into()),
    }
}

async fn start_proxy_bridge(env_uuid: &str, upstream: AuthenticatedSocks5Proxy) -> Result<u16> {
    stop_proxy_bridge(env_uuid).await;

    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .await
        .map_err(|error| format!("无法创建本地 SOCKS5 认证桥: {error}"))?;
    let local_port = listener
        .local_addr()
        .map_err(|error| format!("无法读取本地 SOCKS5 认证桥端口: {error}"))?
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
                                if let Err(error) = handle_client(stream, connection_upstream).await {
                                    log::warn!(
                                        "SOCKS5 proxy bridge connection failed for env_uuid={}: {}",
                                        connection_env_id,
                                        error
                                    );
                                }
                            });
                        }
                        Err(error) => {
                            log::warn!(
                                "SOCKS5 proxy bridge listener stopped for env_uuid={}: {}",
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
                            "SOCKS5 proxy bridge task failed for env_uuid={}: {}",
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

async fn handle_client(
    mut client: TcpStream,
    upstream: AuthenticatedSocks5Proxy,
) -> std::result::Result<(), String> {
    negotiate_no_auth(&mut client).await?;
    let target = read_connect_target(&mut client).await?;

    let mut remote = match tokio::time::timeout(
        UPSTREAM_CONNECT_TIMEOUT,
        Socks5Stream::connect_with_password(
            (upstream.host.as_str(), upstream.port),
            target,
            &upstream.username,
            &upstream.password,
        ),
    )
    .await
    {
        Ok(Ok(stream)) => stream,
        Ok(Err(error)) => {
            let _ = send_reply(&mut client, 0x01).await;
            return Err(format!("上游 SOCKS5 认证/连接失败: {error}"));
        }
        Err(_) => {
            let _ = send_reply(&mut client, 0x04).await;
            return Err("上游 SOCKS5 连接超时".to_string());
        }
    };

    send_reply(&mut client, 0x00).await?;
    tokio::io::copy_bidirectional(&mut client, &mut remote)
        .await
        .map_err(|error| format!("SOCKS5 双向转发失败: {error}"))?;
    Ok(())
}

async fn negotiate_no_auth(client: &mut TcpStream) -> std::result::Result<(), String> {
    let mut header = [0_u8; 2];
    client
        .read_exact(&mut header)
        .await
        .map_err(|error| format!("读取 SOCKS5 握手失败: {error}"))?;
    if header[0] != 0x05 {
        return Err(format!("不支持的 SOCKS 版本: {}", header[0]));
    }

    let mut methods = vec![0_u8; header[1] as usize];
    client
        .read_exact(&mut methods)
        .await
        .map_err(|error| format!("读取 SOCKS5 认证方式失败: {error}"))?;
    if !methods.contains(&0x00) {
        let _ = client.write_all(&[0x05, 0xff]).await;
        return Err("浏览器没有提供 SOCKS5 no-auth 握手方式".to_string());
    }

    client
        .write_all(&[0x05, 0x00])
        .await
        .map_err(|error| format!("写入 SOCKS5 握手响应失败: {error}"))?;
    Ok(())
}

async fn read_connect_target(
    client: &mut TcpStream,
) -> std::result::Result<TargetAddr<'static>, String> {
    let mut header = [0_u8; 4];
    client
        .read_exact(&mut header)
        .await
        .map_err(|error| format!("读取 SOCKS5 CONNECT 请求失败: {error}"))?;

    if header[0] != 0x05 {
        return Err(format!("不支持的 SOCKS 版本: {}", header[0]));
    }
    if header[1] != 0x01 {
        let _ = send_reply(client, 0x07).await;
        return Err(format!("仅支持 SOCKS5 CONNECT，收到命令 {}", header[1]));
    }

    match header[3] {
        0x01 => {
            let mut address = [0_u8; 4];
            client
                .read_exact(&mut address)
                .await
                .map_err(|error| format!("读取 SOCKS5 IPv4 目标失败: {error}"))?;
            let port = read_port(client).await?;
            Ok(TargetAddr::Ip(SocketAddr::new(
                IpAddr::V4(Ipv4Addr::from(address)),
                port,
            )))
        }
        0x03 => {
            let mut length = [0_u8; 1];
            client
                .read_exact(&mut length)
                .await
                .map_err(|error| format!("读取 SOCKS5 域名长度失败: {error}"))?;
            let mut domain = vec![0_u8; length[0] as usize];
            client
                .read_exact(&mut domain)
                .await
                .map_err(|error| format!("读取 SOCKS5 域名失败: {error}"))?;
            let domain = String::from_utf8(domain)
                .map_err(|_| "SOCKS5 目标域名不是有效 UTF-8".to_string())?;
            let port = read_port(client).await?;
            Ok(TargetAddr::Domain(domain.into(), port))
        }
        0x04 => {
            let mut address = [0_u8; 16];
            client
                .read_exact(&mut address)
                .await
                .map_err(|error| format!("读取 SOCKS5 IPv6 目标失败: {error}"))?;
            let port = read_port(client).await?;
            Ok(TargetAddr::Ip(SocketAddr::new(
                IpAddr::V6(Ipv6Addr::from(address)),
                port,
            )))
        }
        address_type => {
            let _ = send_reply(client, 0x08).await;
            Err(format!("不支持的 SOCKS5 地址类型: {address_type}"))
        }
    }
}

async fn read_port(client: &mut TcpStream) -> std::result::Result<u16, String> {
    let mut port = [0_u8; 2];
    client
        .read_exact(&mut port)
        .await
        .map_err(|error| format!("读取 SOCKS5 目标端口失败: {error}"))?;
    Ok(u16::from_be_bytes(port))
}

async fn send_reply(client: &mut TcpStream, reply: u8) -> std::result::Result<(), String> {
    client
        .write_all(&[0x05, reply, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        .await
        .map_err(|error| format!("写入 SOCKS5 响应失败: {error}"))
}

fn normalize_connect_host(host: &str) -> String {
    let host = host.trim();
    host.strip_prefix('[')
        .and_then(|value| value.strip_suffix(']'))
        .unwrap_or(host)
        .to_string()
}
