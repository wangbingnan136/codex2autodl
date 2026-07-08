use anyhow::{Context, Result};
use keyring::{Entry, Error};

const SERVICE: &str = "codex2autodl";

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

fn entry(kind: SecretKind, alias: &str) -> Result<Entry> {
    Entry::new(SERVICE, &format!("{}:{alias}", kind.account_prefix()))
        .with_context(|| "failed to open system keychain")
}
