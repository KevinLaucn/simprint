<div align="center">
  <h1>Simprint Server</h1>
  <p>Legacy standalone backend retained from Simprint's earlier hosted architecture.</p>
  <p>
    <img alt="Language Rust 2024" src="https://img.shields.io/badge/language-Rust%202024-f97316?style=flat-square&labelColor=0f172a" />
    <img alt="Framework Axum 0.8" src="https://img.shields.io/badge/framework-Axum%200.8-60a5fa?style=flat-square&labelColor=0f172a" />
    <img alt="Database PostgreSQL" src="https://img.shields.io/badge/database-PostgreSQL-38bdf8?style=flat-square&labelColor=0f172a" />
  </p>
  <p>
    <strong>English</strong> | <a href="./README.zh-CN.md">简体中文</a>
  </p>
</div>

---

> [!IMPORTANT]
> The current Simprint desktop application is local-first. It stores application data in an embedded SQLite database and runs the environment runtime in-process. You do not need to deploy this server, PostgreSQL, Redis, or a remote API to install, use, or develop the desktop application.

## Current role

This directory contains the standalone Axum and PostgreSQL backend from Simprint's earlier hosted-product architecture. It remains in the repository for maintenance, migration reference, and explicitly scoped server work, but it is not part of the default desktop runtime path.

In particular:

- `cargo tauri dev` does not build or start this project.
- The desktop application does not require a `base_url` pointing to it.
- Desktop users and contributors should follow the root [README](../README.md) and [development guide](../docs/development-setup.zh-CN.md).
- New desktop features should use the embedded business layer in `src-tauri/crates/business` unless the project explicitly decides otherwise.

## Maintainer setup

Only use the instructions below when your work directly targets `server/`.

### Prerequisites

- Rust stable
- PostgreSQL
- Optional SMTP credentials for email flows
- Resource download URLs suitable for the feature being tested

The current local configuration does not define a Redis connection. PostgreSQL is the required external data service for this standalone component.

### Run locally

From the `server` directory:

```bash
cp configs/config.local.example.toml configs/config.local.toml
# Review the local-only secrets and PostgreSQL connection before running.
cargo run -- -f configs/config.local.toml
```

The example listens on `127.0.0.1:40041` with the `/api/v1` prefix. It runs the migrations in `server/migrations` during startup.

### Validate changes

```bash
cargo fmt -- --check
cargo check
cargo test
```

Keep server changes separate from desktop changes when possible, and state clearly in the pull request that the work targets this legacy standalone component.

## Deployment artifacts

The repository still contains historical Docker packaging and deployment scripts. They are retained for maintenance and migration work; they are not the recommended installation path for the current desktop application. Review generated configuration, secrets, image sources, and exposed ports before using those artifacts in any environment.

## License

This component is covered by the repository's GNU Affero General Public License v3.0 (AGPLv3).
