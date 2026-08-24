<div align="center">
  <h1>Simprint Server</h1>
  <p>从 Simprint 早期在线架构保留下来的遗留独立服务端。</p>
  <p>
    <img alt="Language Rust 2024" src="https://img.shields.io/badge/language-Rust%202024-f97316?style=flat-square&labelColor=0f172a" />
    <img alt="Framework Axum 0.8" src="https://img.shields.io/badge/framework-Axum%200.8-60a5fa?style=flat-square&labelColor=0f172a" />
    <img alt="Database PostgreSQL" src="https://img.shields.io/badge/database-PostgreSQL-38bdf8?style=flat-square&labelColor=0f172a" />
  </p>
  <p>
    <a href="./README.md">English</a> | <strong>简体中文</strong>
  </p>
</div>

---

> [!IMPORTANT]
> 当前 Simprint 桌面端采用 local-first 架构：业务数据保存在内嵌 SQLite 数据库中，环境运行时与主程序同进程运行。安装、使用或开发桌面端都不需要部署本服务端，也不需要 PostgreSQL、Redis 或远程业务 API。

## 当前定位

本目录包含 Simprint 早期在线产品架构中的 Axum + PostgreSQL 独立后端。目前保留它主要用于历史代码维护、迁移参考，以及范围明确的服务端开发；它不属于桌面端默认运行链路。

具体来说：

- `cargo tauri dev` 不会编译或启动本工程。
- 桌面端不需要配置指向它的 `base_url`。
- 桌面端用户和贡献者应阅读根目录 [README](../README.zh-CN.md) 与 [开发配置文档](../docs/development-setup.zh-CN.md)。
- 新的桌面功能应使用 `src-tauri/crates/business` 中的内嵌业务层，除非项目另行明确决定。

## 维护者配置

只有变更明确针对 `server/` 时，才使用下面的说明。

### 前置条件

- Rust stable
- PostgreSQL
- 邮件流程需要的可选 SMTP 配置
- 与待测功能匹配的资源下载地址

当前本地配置没有 Redis 连接项。PostgreSQL 是这个独立组件必需的外部数据服务。

### 本地运行

在 `server` 目录执行：

```bash
cp configs/config.local.example.toml configs/config.local.toml
# 启动前检查仅供本地使用的密钥和 PostgreSQL 连接。
cargo run -- -f configs/config.local.toml
```

示例配置监听 `127.0.0.1:40041`，接口前缀为 `/api/v1`。启动时会执行 `server/migrations` 中的迁移。

### 验证变更

```bash
cargo fmt -- --check
cargo check
cargo test
```

服务端与桌面端变更应尽量拆分，并在 Pull Request 中明确说明变更面向这个遗留独立组件。

## 部署产物

仓库中仍保留历史 Docker 打包和部署脚本，用于维护与迁移工作；它们不是当前桌面应用的推荐安装方式。在任何环境使用这些产物前，都应重新检查生成的配置、密钥、镜像来源和开放端口。

## License

本组件遵循仓库的 GNU Affero General Public License v3.0 (AGPLv3) 许可。
