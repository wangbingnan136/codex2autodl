use crate::paths::home_dir;
use anyhow::{Context, Result};
use keyring::{Entry, Error};
use std::process::{Command, Stdio};

const SERVICE: &str = "codex2autodl";
const CCR_CODEX_KEY_QUERY: &str = "SELECT encrypted_key FROM api_keys \
WHERE id='profile:default-codex' AND encryption='plain' LIMIT 1;";

#[derive(Clone, Copy)]
pub enum SecretKind {
    SshPassword,
    ApiKey,
}

impl SecretKind {
    fn account_prefix(self) -> &'static str {
        match self {
            Self::SshPassword => "ssh",
            Self::ApiKey => "api",
        }
    }
}

pub fn set_secret(kind: SecretKind, alias: &str, value: &str) -> Result<()> {
    let value = value.trim();
    if value.is_empty() {
        return Ok(());
    }

    entry(kind, alias)?.set_password(value).with_context(|| {
        format!(
            "failed to save {} secret for {alias}",
            kind.account_prefix()
        )
    })
}

pub fn get_secret(kind: SecretKind, alias: &str) -> Result<Option<String>> {
    match entry(kind, alias)?.get_password() {
        Ok(value) => Ok(Some(value)),
        Err(Error::NoEntry) => Ok(None),
        Err(err) => Err(err).with_context(|| {
            format!(
                "failed to read {} secret for {alias}",
                kind.account_prefix()
            )
        }),
    }
}

pub fn has_secret(kind: SecretKind, alias: &str) -> bool {
    if let Some(exists) = secret_exists_without_unlock(kind, alias) {
        return exists;
    }
    get_secret(kind, alias).ok().flatten().is_some()
}

#[cfg(target_os = "macos")]
fn secret_exists_without_unlock(kind: SecretKind, alias: &str) -> Option<bool> {
    use std::process::{Command, Stdio};

    let account = format!("{}:{alias}", kind.account_prefix());
    Command::new("security")
        .args(["find-generic-password", "-s", SERVICE, "-a", &account])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .ok()
        .map(|status| status.success())
}

#[cfg(not(target_os = "macos"))]
fn secret_exists_without_unlock(_kind: SecretKind, _alias: &str) -> Option<bool> {
    None
}

pub fn delete_secret(kind: SecretKind, alias: &str) -> Result<()> {
    let Ok(entry) = entry(kind, alias) else {
        return Ok(());
    };

    match entry.delete_credential() {
        Ok(()) | Err(Error::NoEntry) => Ok(()),
        Err(_) => Ok(()),
    }
}

pub fn current_ccr_codex_api_key() -> Option<String> {
    let database = home_dir()
        .ok()?
        .join(".claude-code-router/app-data/api-keys.sqlite");
    if !database.is_file() {
        return None;
    }

    let output = Command::new("sqlite3")
        .arg("-readonly")
        .arg(database)
        .arg(CCR_CODEX_KEY_QUERY)
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    parse_ccr_codex_api_key(&String::from_utf8(output.stdout).ok()?)
}

fn parse_ccr_codex_api_key(output: &str) -> Option<String> {
    let mut values = output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty());
    let value = values.next()?;
    if values.next().is_some() || !value.starts_with("ccr-profile-") {
        return None;
    }
    Some(value.to_string())
}

fn entry(kind: SecretKind, alias: &str) -> Result<Entry> {
    Entry::new(SERVICE, &format!("{}:{alias}", kind.account_prefix()))
        .with_context(|| "failed to open system keychain")
}

#[cfg(test)]
mod tests {
    use super::parse_ccr_codex_api_key;

    #[test]
    fn parses_single_ccr_codex_key() {
        assert_eq!(
            parse_ccr_codex_api_key("ccr-profile-current_key\n").as_deref(),
            Some("ccr-profile-current_key")
        );
    }

    #[test]
    fn rejects_non_ccr_or_multiple_keys() {
        assert!(parse_ccr_codex_api_key("sk-not-ccr\n").is_none());
        assert!(parse_ccr_codex_api_key("ccr-profile-one\nccr-profile-two\n").is_none());
    }
}
