use crate::paths::home_dir;
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct LocalModelDefaults {
    pub local_api_port: u16,
    pub remote_api_port: u16,
    pub api_provider_name: String,
    pub wire_api: String,
    pub model: Option<String>,
    pub model_catalog_path: Option<String>,
}

impl LocalModelDefaults {
    pub fn detect() -> Self {
        let home = home_dir().unwrap_or_else(|_| PathBuf::from("."));
        let codex_home = std::env::var_os("CODEX_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".codex"));
        let config = fs::read_to_string(codex_home.join("config.toml")).unwrap_or_default();
        parse_config(&config, &home, &codex_home)
    }
}

fn parse_config(config: &str, home: &Path, codex_home: &Path) -> LocalModelDefaults {
    let mut provider = None;
    let mut model = None;
    let mut catalog = None;
    let mut provider_base_url = None;
    let mut wire_api = None;
    let mut section = String::new();

    for raw_line in config.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            section = line[1..line.len() - 1].trim().to_string();
            continue;
        }

        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        let Some(value) = quoted_value(value.trim()) else {
            continue;
        };

        if section.is_empty() {
            match key {
                "model_provider" => provider = Some(value),
                "model" => model = Some(value),
                "model_catalog_json" => catalog = Some(value),
                _ => {}
            }
            continue;
        }

        if provider
            .as_ref()
            .is_some_and(|name| section == format!("model_providers.{name}"))
        {
            match key {
                "base_url" => provider_base_url = Some(value),
                "wire_api" => wire_api = Some(value),
                _ => {}
            }
        }
    }

    let fallback_catalog = codex_home.join("ccr-model-catalog.json");
    let catalog = catalog
        .map(|path| expand_home(&path, home))
        .filter(|path| path.is_file())
        .or_else(|| fallback_catalog.is_file().then_some(fallback_catalog));
    let port = provider_base_url
        .as_deref()
        .and_then(loopback_port)
        .unwrap_or(18990);

    LocalModelDefaults {
        local_api_port: port,
        remote_api_port: port,
        api_provider_name: provider.unwrap_or_else(|| "claude-code-router".to_string()),
        wire_api: wire_api.unwrap_or_else(|| "responses".to_string()),
        model: model.or_else(|| Some("codex2api/gpt-5.5".to_string())),
        model_catalog_path: catalog.map(|path| path.display().to_string()),
    }
}

fn quoted_value(value: &str) -> Option<String> {
    let value = value.strip_prefix('"')?;
    let end = value.find('"')?;
    Some(value[..end].to_string())
}

fn expand_home(path: &str, home: &Path) -> PathBuf {
    if path == "~" {
        return home.to_path_buf();
    }
    if let Some(rest) = path.strip_prefix("~/") {
        return home.join(rest);
    }
    PathBuf::from(path)
}

fn loopback_port(url: &str) -> Option<u16> {
    let rest = url
        .strip_prefix("http://")
        .or_else(|| url.strip_prefix("https://"))?;
    let authority = rest.split('/').next()?;
    let (host, port) = authority.rsplit_once(':')?;
    matches!(host, "127.0.0.1" | "localhost" | "[::1]")
        .then(|| port.parse().ok())
        .flatten()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_active_local_provider_defaults() {
        let home = Path::new("/Users/test");
        let codex_home = home.join(".codex");
        let defaults = parse_config(
            r#"
model_provider = "claude-code-router"
model = "codex2api/gpt-5.6-sol"
model_catalog_json = "~/.codex/catalog.json"

[model_providers.claude-code-router]
base_url = "http://127.0.0.1:18890/v1"
wire_api = "responses"
"#,
            home,
            &codex_home,
        );

        assert_eq!(defaults.local_api_port, 18890);
        assert_eq!(defaults.api_provider_name, "claude-code-router");
        assert_eq!(defaults.model.as_deref(), Some("codex2api/gpt-5.6-sol"));
        assert_eq!(defaults.wire_api, "responses");
    }

    #[test]
    fn parses_only_loopback_provider_ports() {
        assert_eq!(loopback_port("http://localhost:8080/v1"), Some(8080));
        assert_eq!(loopback_port("https://127.0.0.1:18890/v1"), Some(18890));
        assert_eq!(loopback_port("https://example.com:443/v1"), None);
    }
}
