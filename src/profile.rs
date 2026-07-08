use crate::paths::ProjectPaths;
use crate::secrets::{self, SecretKind};
use crate::ssh::{self, TunnelState};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::sync::{Arc, Mutex};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

#[derive(Clone)]
pub struct ProfileStore {
    path: Arc<std::path::PathBuf>,
    profiles: Arc<Mutex<BTreeMap<String, Profile>>>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Profile {
    pub alias: String,
    pub ssh_command: String,
    pub user: String,
    pub host: String,
    pub port: u16,
    pub local_api_port: u16,
    pub remote_api_port: u16,
    pub api_provider_name: String,
    pub note: String,
    pub tags: Vec<String>,
    pub created_at: String,
    pub updated_at: String,
    pub last_connected_at: Option<String>,
    pub last_status: ProfileStatus,
    pub last_message: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProfileStatus {
    New,
    Running,
    Connected,
    Failed,
    Stopped,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SaveProfileRequest {
    pub alias: String,
    pub ssh_command: String,
    pub ssh_password: Option<String>,
    pub api_key: Option<String>,
    pub local_api_port: Option<u16>,
    pub remote_api_port: Option<u16>,
    pub api_provider_name: Option<String>,
    pub note: Option<String>,
    pub tags: Option<Vec<String>>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ProfileView {
    #[serde(flatten)]
    pub profile: Profile,
    pub has_ssh_password: bool,
    pub has_api_key: bool,
    pub tunnel_state: TunnelState,
    pub health_score: u8,
}

impl ProfileStore {
    pub fn load(paths: &ProjectPaths) -> Result<Self> {
        let mut profiles = if paths.profiles_file.is_file() {
            let text = fs::read_to_string(&paths.profiles_file).with_context(|| {
                format!(
                    "failed to read profiles file: {}",
                    paths.profiles_file.display()
                )
            })?;
            serde_json::from_str::<BTreeMap<String, Profile>>(&text)
                .context("failed to parse profiles file")?
        } else {
            BTreeMap::new()
        };

        for imported in ssh::import_managed_ssh_hosts() {
            profiles
                .entry(imported.alias.clone())
                .or_insert_with(|| Profile {
                    alias: imported.alias.clone(),
                    ssh_command: format!(
                        "ssh -p {} {}@{}",
                        imported.port, imported.user, imported.host
                    ),
                    user: imported.user,
                    host: imported.host,
                    port: imported.port,
                    local_api_port: 8080,
                    remote_api_port: 8080,
                    api_provider_name: "codex2api".to_string(),
                    note: "Imported from ~/.ssh/config".to_string(),
                    tags: vec!["imported".to_string()],
                    created_at: now_string(),
                    updated_at: now_string(),
                    last_connected_at: None,
                    last_status: ProfileStatus::New,
                    last_message: "等待连接".to_string(),
                });
        }
        reconcile_loaded_profile_statuses(&mut profiles);

        let store = Self {
            path: Arc::new(paths.profiles_file.clone()),
            profiles: Arc::new(Mutex::new(profiles)),
        };
        store.persist()?;
        Ok(store)
    }

    pub fn list_views(&self) -> Vec<ProfileView> {
        let profiles = self
            .profiles
            .lock()
            .expect("profiles lock poisoned")
            .values()
            .cloned()
            .collect::<Vec<_>>();
        let tunnel_checks = profiles
            .iter()
            .map(|profile| {
                let alias = profile.alias.clone();
                let remote_port = profile.remote_api_port;
                std::thread::spawn(move || ssh::managed_tunnel_state(&alias, remote_port))
            })
            .collect::<Vec<_>>();
        profiles
            .into_iter()
            .zip(tunnel_checks)
            .map(|(profile, tunnel_check)| {
                let has_ssh_password = secrets::has_secret(SecretKind::SshPassword, &profile.alias);
                let has_api_key = secrets::has_secret(SecretKind::ApiKey, &profile.alias);
                let tunnel_state = tunnel_check
                    .join()
                    .unwrap_or(crate::ssh::TunnelState::Stale);
                let health_score =
                    health_score(&profile.last_status, has_ssh_password, &tunnel_state);
                ProfileView {
                    profile,
                    has_ssh_password,
                    has_api_key,
                    tunnel_state,
                    health_score,
                }
            })
            .collect()
    }

    pub fn get(&self, alias: &str) -> Option<Profile> {
        self.profiles
            .lock()
            .expect("profiles lock poisoned")
            .get(alias)
            .cloned()
    }

    pub fn save(&self, request: SaveProfileRequest) -> Result<Profile> {
        let alias = request.alias.trim();
        ssh::validate_alias(alias)?;
        let target = ssh::parse_ssh_command(request.ssh_command.trim())?;

        if let Some(password) = request.ssh_password.as_deref() {
            secrets::set_secret(SecretKind::SshPassword, alias, password)?;
        }
        if let Some(api_key) = request.api_key.as_deref() {
            secrets::set_secret(SecretKind::ApiKey, alias, api_key)?;
        }

        let mut profiles = self.profiles.lock().expect("profiles lock poisoned");
        let existing = profiles.get(alias).cloned();
        let now = now_string();
        let profile = Profile {
            alias: alias.to_string(),
            ssh_command: request.ssh_command.trim().to_string(),
            user: target.user,
            host: target.host,
            port: target.port,
            local_api_port: request.local_api_port.unwrap_or(8080),
            remote_api_port: request
                .remote_api_port
                .unwrap_or_else(|| request.local_api_port.unwrap_or(8080)),
            api_provider_name: request
                .api_provider_name
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| "codex2api".to_string()),
            note: request.note.unwrap_or_default(),
            tags: request.tags.unwrap_or_default(),
            created_at: existing
                .as_ref()
                .map(|profile| profile.created_at.clone())
                .unwrap_or_else(|| now.clone()),
            updated_at: now,
            last_connected_at: existing
                .as_ref()
                .and_then(|profile| profile.last_connected_at.clone()),
            last_status: existing
                .as_ref()
                .map(|profile| profile.last_status.clone())
                .unwrap_or(ProfileStatus::New),
            last_message: existing
                .map(|profile| profile.last_message)
                .unwrap_or_else(|| "等待连接".to_string()),
        };
        profiles.insert(alias.to_string(), profile.clone());
        drop(profiles);
        self.persist()?;
        Ok(profile)
    }

    pub fn remove(&self, alias: &str) -> Result<()> {
        self.profiles
            .lock()
            .expect("profiles lock poisoned")
            .remove(alias);
        secrets::delete_secret(SecretKind::SshPassword, alias)?;
        secrets::delete_secret(SecretKind::ApiKey, alias)?;
        ssh::remove_codex2autodl_alias(alias)?;
        self.persist()
    }

    pub fn mark_status(
        &self,
        alias: &str,
        status: ProfileStatus,
        message: impl Into<String>,
    ) -> Result<()> {
        let mut profiles = self.profiles.lock().expect("profiles lock poisoned");
        if let Some(profile) = profiles.get_mut(alias) {
            let now = now_string();
            profile.last_status = status.clone();
            profile.last_message = message.into();
            profile.updated_at = now.clone();
            if status == ProfileStatus::Connected {
                profile.last_connected_at = Some(now);
            }
        }
        drop(profiles);
        self.persist()
    }

    fn persist(&self) -> Result<()> {
        let profiles = self.profiles.lock().expect("profiles lock poisoned");
        let text = serde_json::to_string_pretty(&*profiles)?;
        let tmp = self.path.with_extension("json.tmp");
        fs::write(&tmp, text)
            .with_context(|| format!("failed to write profiles file: {}", tmp.display()))?;
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600)).ok();
        fs::rename(&tmp, self.path.as_ref()).with_context(|| {
            format!(
                "failed to replace profiles file: {}",
                self.path.as_ref().display()
            )
        })?;
        Ok(())
    }
}

fn health_score(status: &ProfileStatus, has_password: bool, tunnel: &TunnelState) -> u8 {
    let mut score = match (status, tunnel) {
        (ProfileStatus::Connected, TunnelState::Running) => 94,
        (ProfileStatus::Connected, TunnelState::Stale | TunnelState::Missing) => 48,
        (ProfileStatus::Running, TunnelState::Running) => 82,
        (ProfileStatus::Running, TunnelState::Stale | TunnelState::Missing) => 36,
        (ProfileStatus::Stopped, TunnelState::Running) => 72,
        (ProfileStatus::Stopped, TunnelState::Stale | TunnelState::Missing) => 58,
        (ProfileStatus::Failed, TunnelState::Running) => 50,
        (ProfileStatus::Failed, TunnelState::Stale | TunnelState::Missing) => 32,
        (ProfileStatus::New, TunnelState::Running) => 74,
        (ProfileStatus::New, TunnelState::Stale | TunnelState::Missing) => 64,
    };

    if has_password {
        score += 5;
    }
    if matches!(tunnel, TunnelState::Running) {
        score += 4;
    }

    score.min(100)
}

fn reconcile_loaded_profile_statuses(profiles: &mut BTreeMap<String, Profile>) {
    for profile in profiles.values_mut() {
        if profile.last_status != ProfileStatus::Running {
            continue;
        }

        if matches!(
            ssh::managed_tunnel_state(&profile.alias, profile.remote_api_port),
            TunnelState::Running
        ) {
            continue;
        }

        profile.last_status = ProfileStatus::Stopped;
        profile.last_message = "上次任务未正常结束，隧道未运行".to_string();
        profile.updated_at = now_string();
    }
}

pub fn now_string() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}
