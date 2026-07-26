use crate::local_codex::LocalModelDefaults;
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
    #[serde(default = "default_wire_api")]
    pub wire_api: String,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub model_catalog_path: Option<String>,
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
    pub wire_api: Option<String>,
    pub model: Option<String>,
    pub model_catalog_path: Option<String>,
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
        let model_defaults = LocalModelDefaults::detect();
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
            let defaults = model_defaults.clone();
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
                    local_api_port: defaults.local_api_port,
                    remote_api_port: defaults.remote_api_port,
                    api_provider_name: defaults.api_provider_name,
                    wire_api: defaults.wire_api,
                    model: defaults.model,
                    model_catalog_path: defaults.model_catalog_path,
                    note: "Imported from ~/.ssh/config".to_string(),
                    tags: vec!["imported".to_string()],
                    created_at: now_string(),
                    updated_at: now_string(),
                    last_connected_at: None,
                    last_status: ProfileStatus::New,
                    last_message: "等待连接".to_string(),
                });
        }
        migrate_missing_model_settings(&mut profiles, &model_defaults);
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
        let mut dirty = false;
        let views = profiles
            .into_iter()
            .zip(tunnel_checks)
            .map(|(mut profile, tunnel_check)| {
                let has_ssh_password = secrets::has_secret(SecretKind::SshPassword, &profile.alias);
                let has_api_key = secrets::has_secret(SecretKind::ApiKey, &profile.alias);
                let tunnel_state = tunnel_check
                    .join()
                    .unwrap_or(crate::ssh::TunnelState::Stale);
                if heal_profile_status_from_tunnel(&mut profile, &tunnel_state) {
                    dirty = true;
                }
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
            .collect::<Vec<_>>();

        if dirty {
            // 隧道已恢复健康时，把 failed/running 旧状态写回 connected，面板不长期显示 -1。
            let mut profiles = self.profiles.lock().expect("profiles lock poisoned");
            for view in &views {
                if let Some(stored) = profiles.get_mut(&view.profile.alias) {
                    *stored = view.profile.clone();
                }
            }
            drop(profiles);
            let _ = self.persist();
        }

        views
    }

    pub fn get(&self, alias: &str) -> Option<Profile> {
        self.profiles
            .lock()
            .expect("profiles lock poisoned")
            .get(alias)
            .cloned()
    }

    pub fn list(&self) -> Vec<Profile> {
        self.profiles
            .lock()
            .expect("profiles lock poisoned")
            .values()
            .cloned()
            .collect()
    }

    pub fn model_defaults(&self) -> LocalModelDefaults {
        LocalModelDefaults::detect()
    }

    /// 是否存在"本应有隧道却掉线"的 profile(供后台健康巡检使用)。
    /// 只考虑上次状态为 Connected/Running 的 profile,避免对从未连接或已主动停止
    /// 的 profile 反复触发修复。会执行 SSH 探测,可能阻塞,调用方应放在 blocking 上下文。
    pub fn has_unhealthy_tunnel(&self) -> bool {
        let targets = self
            .profiles
            .lock()
            .expect("profiles lock poisoned")
            .values()
            .filter(|profile| {
                matches!(
                    profile.last_status,
                    ProfileStatus::Connected | ProfileStatus::Running
                )
            })
            .map(|profile| (profile.alias.clone(), profile.remote_api_port))
            .collect::<Vec<_>>();

        targets.iter().any(|(alias, remote_port)| {
            !matches!(
                ssh::managed_tunnel_state(alias, *remote_port),
                TunnelState::Running
            )
        })
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
        let defaults = LocalModelDefaults::detect();
        let now = now_string();
        let profile = Profile {
            alias: alias.to_string(),
            ssh_command: request.ssh_command.trim().to_string(),
            user: target.user,
            host: target.host,
            port: target.port,
            local_api_port: request
                .local_api_port
                .or_else(|| existing.as_ref().map(|profile| profile.local_api_port))
                .unwrap_or(defaults.local_api_port),
            remote_api_port: request
                .remote_api_port
                .or(request.local_api_port)
                .or_else(|| existing.as_ref().map(|profile| profile.remote_api_port))
                .unwrap_or(defaults.remote_api_port),
            api_provider_name: request
                .api_provider_name
                .filter(|value| !value.trim().is_empty())
                .or_else(|| {
                    existing
                        .as_ref()
                        .map(|profile| profile.api_provider_name.clone())
                })
                .unwrap_or_else(|| defaults.api_provider_name.clone()),
            wire_api: request
                .wire_api
                .filter(|value| !value.trim().is_empty())
                .or_else(|| existing.as_ref().map(|profile| profile.wire_api.clone()))
                .unwrap_or_else(|| defaults.wire_api.clone()),
            model: request
                .model
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
                .or_else(|| existing.as_ref().and_then(|profile| profile.model.clone()))
                .or_else(|| defaults.model.clone()),
            model_catalog_path: request
                .model_catalog_path
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty())
                .or_else(|| {
                    existing
                        .as_ref()
                        .and_then(|profile| profile.model_catalog_path.clone())
                })
                .or_else(|| defaults.model_catalog_path.clone()),
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
        let tunnel = ssh::managed_tunnel_state(&profile.alias, profile.remote_api_port);
        if heal_profile_status_from_tunnel(profile, &tunnel) {
            continue;
        }

        // 面板/任务中断后仍标 running，但隧道已不在，降成 stopped，避免永久“任务运行中”。
        if profile.last_status == ProfileStatus::Running {
            profile.last_status = ProfileStatus::Stopped;
            profile.last_message = "上次任务未正常结束，隧道未运行".to_string();
            profile.updated_at = now_string();
        }
    }
}

fn migrate_missing_model_settings(
    profiles: &mut BTreeMap<String, Profile>,
    defaults: &LocalModelDefaults,
) {
    for profile in profiles.values_mut() {
        let uses_legacy_fallback =
            profile.model_catalog_path.as_deref() == Some("~/.codex/ccr-model-catalog.json");
        if profile.model_catalog_path.is_some() && !uses_legacy_fallback {
            continue;
        }

        profile.local_api_port = defaults.local_api_port;
        profile.remote_api_port = defaults.remote_api_port;
        profile.api_provider_name = defaults.api_provider_name.clone();
        profile.wire_api = defaults.wire_api.clone();
        profile.model = defaults.model.clone();
        profile.model_catalog_path = defaults.model_catalog_path.clone();
        profile.updated_at = now_string();
    }
}

/// 隧道实际 Running 时，把 failed/running/stopped/new 等过期状态回写 connected。
/// 返回 true 表示改动了 profile。
fn heal_profile_status_from_tunnel(profile: &mut Profile, tunnel: &TunnelState) -> bool {
    if !matches!(tunnel, TunnelState::Running) {
        return false;
    }
    if profile.last_status == ProfileStatus::Connected {
        return false;
    }

    let now = now_string();
    profile.last_status = ProfileStatus::Connected;
    profile.last_message = "隧道运行中".to_string();
    profile.updated_at = now.clone();
    profile.last_connected_at = Some(now);
    true
}

pub fn now_string() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

pub fn default_wire_api() -> String {
    "responses".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp_paths() -> (ProjectPaths, PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "codex2autodl-test-{}-{}",
            std::process::id(),
            OffsetDateTime::now_utc().unix_timestamp_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        let paths = ProjectPaths {
            project_root: dir.clone(),
            data_dir: dir.clone(),
            profiles_file: dir.join("profiles.json"),
            setup_script: dir.join("scripts/setup-autodl-codex.sh"),
        };
        (paths, dir)
    }

    #[test]
    fn health_score_connected_running_is_high() {
        // 94 基础 + 4(隧道 Running)= 98
        let score = health_score(&ProfileStatus::Connected, false, &TunnelState::Running);
        assert_eq!(score, 98);
    }

    #[test]
    fn health_score_password_bonus_and_cap() {
        // 94 + 5(密码) + 4(Running) = 103 -> 截断到 100
        let score = health_score(&ProfileStatus::Connected, true, &TunnelState::Running);
        assert_eq!(score, 100);
    }

    #[test]
    fn health_score_stale_tunnel_lower_than_running() {
        let running = health_score(&ProfileStatus::Connected, false, &TunnelState::Running);
        let stale = health_score(&ProfileStatus::Connected, false, &TunnelState::Stale);
        let missing = health_score(&ProfileStatus::Connected, false, &TunnelState::Missing);
        assert!(stale < running);
        assert_eq!(stale, missing);
    }

    #[test]
    fn health_score_never_exceeds_100() {
        for status in [
            ProfileStatus::New,
            ProfileStatus::Running,
            ProfileStatus::Connected,
            ProfileStatus::Failed,
            ProfileStatus::Stopped,
        ] {
            for tunnel in [
                TunnelState::Running,
                TunnelState::Stale,
                TunnelState::Missing,
            ] {
                for pw in [true, false] {
                    assert!(health_score(&status, pw, &tunnel) <= 100);
                }
            }
        }
    }

    #[test]
    fn profile_store_persist_round_trip() {
        let (paths, dir) = temp_paths();
        let store = ProfileStore::load(&paths).unwrap();
        store
            .save(SaveProfileRequest {
                alias: "roundtrip".to_string(),
                ssh_command: "ssh -p 2222 tester@10.0.0.9".to_string(),
                ssh_password: None,
                api_key: None,
                local_api_port: Some(9090),
                remote_api_port: None,
                api_provider_name: None,
                wire_api: None,
                model: None,
                model_catalog_path: None,
                note: Some("hello".to_string()),
                tags: Some(vec!["t1".to_string()]),
            })
            .unwrap();

        // 用新 store 从磁盘重新加载,验证持久化生效。
        let reloaded = ProfileStore::load(&paths).unwrap();
        let profile = reloaded.get("roundtrip").expect("profile persisted");
        assert_eq!(profile.user, "tester");
        assert_eq!(profile.host, "10.0.0.9");
        assert_eq!(profile.port, 2222);
        assert_eq!(profile.local_api_port, 9090);
        // remote 未指定时回退到 local。
        assert_eq!(profile.remote_api_port, 9090);
        assert_eq!(profile.note, "hello");

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn heal_running_tunnel_marks_failed_profile_connected() {
        let mut profile = Profile {
            alias: "healme".to_string(),
            ssh_command: "ssh healhost".to_string(),
            user: "root".to_string(),
            host: "healhost".to_string(),
            port: 22,
            local_api_port: 8080,
            remote_api_port: 8080,
            api_provider_name: "codex2api".to_string(),
            wire_api: default_wire_api(),
            model: None,
            model_catalog_path: None,
            note: String::new(),
            tags: vec![],
            created_at: now_string(),
            updated_at: now_string(),
            last_connected_at: None,
            last_status: ProfileStatus::Failed,
            last_message: "脚本退出码: -1".to_string(),
        };

        assert!(heal_profile_status_from_tunnel(
            &mut profile,
            &TunnelState::Running
        ));
        assert_eq!(profile.last_status, ProfileStatus::Connected);
        assert_eq!(profile.last_message, "隧道运行中");
        assert!(profile.last_connected_at.is_some());

        // 已是 connected 时不再脏写。
        assert!(!heal_profile_status_from_tunnel(
            &mut profile,
            &TunnelState::Running
        ));
        // 隧道不健康时不乱改状态。
        profile.last_status = ProfileStatus::Failed;
        assert!(!heal_profile_status_from_tunnel(
            &mut profile,
            &TunnelState::Stale
        ));
        assert_eq!(profile.last_status, ProfileStatus::Failed);
    }

    #[test]
    fn mark_status_connected_sets_last_connected() {
        let (paths, dir) = temp_paths();
        let store = ProfileStore::load(&paths).unwrap();
        store
            .save(SaveProfileRequest {
                alias: "markme".to_string(),
                ssh_command: "ssh markhost".to_string(),
                ssh_password: None,
                api_key: None,
                local_api_port: None,
                remote_api_port: None,
                api_provider_name: None,
                wire_api: None,
                model: None,
                model_catalog_path: None,
                note: None,
                tags: None,
            })
            .unwrap();
        store
            .mark_status("markme", ProfileStatus::Connected, "ok")
            .unwrap();
        let profile = store.get("markme").unwrap();
        assert_eq!(profile.last_status, ProfileStatus::Connected);
        assert!(profile.last_connected_at.is_some());

        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn migrates_legacy_profiles_to_current_local_model_defaults() {
        let defaults = LocalModelDefaults {
            local_api_port: 18890,
            remote_api_port: 18890,
            api_provider_name: "claude-code-router".to_string(),
            wire_api: "responses".to_string(),
            model: Some("codex2api/gpt-5.6-sol".to_string()),
            model_catalog_path: Some("/Users/test/.codex/catalog.json".to_string()),
        };
        let legacy_profile = |alias: &str, catalog| Profile {
            alias: alias.to_string(),
            ssh_command: format!("ssh {alias}"),
            user: "root".to_string(),
            host: alias.to_string(),
            port: 22,
            local_api_port: 18990,
            remote_api_port: 18990,
            api_provider_name: "claude-code-router".to_string(),
            wire_api: default_wire_api(),
            model: Some("codex2api/gpt-5.5".to_string()),
            model_catalog_path: catalog,
            note: String::new(),
            tags: vec![],
            created_at: now_string(),
            updated_at: now_string(),
            last_connected_at: None,
            last_status: ProfileStatus::New,
            last_message: String::new(),
        };
        let mut profiles = BTreeMap::from([
            (
                "missing".to_string(),
                Profile {
                    model: None,
                    ..legacy_profile("missing", None)
                },
            ),
            (
                "stale".to_string(),
                legacy_profile("stale", Some("~/.codex/ccr-model-catalog.json".to_string())),
            ),
        ]);

        migrate_missing_model_settings(&mut profiles, &defaults);
        for profile in profiles.values() {
            assert_eq!(profile.local_api_port, 18890);
            assert_eq!(profile.remote_api_port, 18890);
            assert_eq!(profile.api_provider_name, "claude-code-router");
            assert_eq!(profile.model.as_deref(), Some("codex2api/gpt-5.6-sol"));
            assert_eq!(
                profile.model_catalog_path.as_deref(),
                Some("/Users/test/.codex/catalog.json")
            );
        }
    }
}
