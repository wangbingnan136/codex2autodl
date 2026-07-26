use crate::paths::home_dir;
use anyhow::{Context, Result, bail};
use serde::Serialize;
use serde_json::Value;
use std::collections::BTreeSet;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Clone, Debug, Serialize)]
pub struct SshTarget {
    pub user: String,
    pub host: String,
    pub port: u16,
}

#[derive(Clone, Debug)]
pub struct ImportedSshHost {
    pub alias: String,
    pub user: String,
    pub host: String,
    pub port: u16,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TunnelState {
    Running,
    Stale,
    Missing,
}

#[derive(Clone, Debug, Serialize)]
pub struct SshHistoryCleanup {
    pub removed_aliases: Vec<String>,
    pub removed_codex_hosts: Vec<String>,
    pub backup_paths: Vec<String>,
}

const CODEX_HOST_KEYED_MAPS: &[&str] = &[
    "agent-mode-by-host-id",
    "preferred-non-full-access-agent-mode-by-host-id",
    "remote-connection-analytics-id-by-host-id",
    "remote-connection-auto-connect-by-host-id",
    "remote-host-globe-color-by-host-id",
    "unread-thread-ids-by-host-v1",
    "unread-thread-ids-by-host-v1-v2",
];
const SSH_BIN: &str = "/usr/bin/ssh";
const KILL_BIN: &str = "/bin/kill";
const LAUNCHCTL_BIN: &str = "/bin/launchctl";
const ID_BIN: &str = "/usr/bin/id";

pub fn validate_alias(alias: &str) -> Result<()> {
    if alias.is_empty()
        || alias.starts_with('-')
        || !alias
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
    {
        bail!(
            "alias can only contain ASCII letters, numbers, dot, underscore, and dash, and cannot start with dash"
        );
    }
    Ok(())
}

pub fn parse_ssh_command(input: &str) -> Result<SshTarget> {
    let tokens = input.split_whitespace().collect::<Vec<_>>();
    if tokens.first().copied() != Some("ssh") {
        bail!("SSH command must start with ssh");
    }

    let mut port: Option<u16> = None;
    let mut user: Option<String> = None;
    let mut host: Option<String> = None;
    let mut i = 1;

    while i < tokens.len() {
        let token = tokens[i];
        match token {
            "-p" => {
                i += 1;
                let value = tokens.get(i).context("-p requires a port")?;
                port = Some(value.parse().context("SSH port must be numeric")?);
            }
            "-l" => {
                i += 1;
                user = Some(tokens.get(i).context("-l requires a user")?.to_string());
            }
            "-o" | "-i" | "-J" => {
                i += 1;
                tokens
                    .get(i)
                    .with_context(|| format!("{token} requires a value"))?;
            }
            value if value.starts_with("-p") && value.len() > 2 => {
                port = Some(value[2..].parse().context("SSH port must be numeric")?);
            }
            value if value.starts_with('-') => {
                bail!("unsupported SSH option in pasted command: {value}");
            }
            value => {
                if value.contains('@') {
                    let mut parts = value.splitn(2, '@');
                    user = parts.next().map(str::to_string).filter(|s| !s.is_empty());
                    host = parts.next().map(str::to_string).filter(|s| !s.is_empty());
                } else if host.is_none() {
                    host = Some(value.to_string());
                }
            }
        }
        i += 1;
    }

    let host = host.context("could not parse SSH host")?;
    let user = user.unwrap_or_else(|| "root".to_string());
    let port = port.unwrap_or(22);

    Ok(SshTarget { user, host, port })
}

pub fn managed_tunnel_state(alias: &str, remote_port: u16) -> TunnelState {
    let Ok(home) = home_dir() else {
        return TunnelState::Missing;
    };
    let ssh_dir = home.join(".ssh");
    let pid_path = ssh_dir.join(format!(
        "codex2autodl-{alias}-proxy-{remote_port}.watchdog.pid"
    ));
    let control_path = ssh_dir.join(format!("codex2autodl-{alias}-proxy-{remote_port}.sock"));

    let Ok(pid) = fs::read_to_string(pid_path) else {
        return TunnelState::Missing;
    };
    let pid = pid.trim();
    if pid.is_empty() {
        return TunnelState::Stale;
    }

    let is_running = Command::new(KILL_BIN)
        .args(["-0", pid])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success());

    if !is_running {
        return TunnelState::Stale;
    }

    if control_master_is_running(alias, &control_path) {
        TunnelState::Running
    } else {
        TunnelState::Stale
    }
}

pub fn control_master_is_running(alias: &str, control_path: &PathBuf) -> bool {
    if !control_path.exists() {
        return false;
    }
    let mut command = Command::new(SSH_BIN);
    command
        .arg("-S")
        .arg(control_path)
        .args(["-O", "check", alias])
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    command_succeeds_with_timeout(command, Duration::from_secs(3))
}

fn command_succeeds_with_timeout(mut command: Command, timeout: Duration) -> bool {
    let Ok(mut child) = command.spawn() else {
        return false;
    };
    let deadline = SystemTime::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None) => {
                if SystemTime::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return false;
                }
                std::thread::sleep(Duration::from_millis(25));
            }
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
        }
    }
}

pub fn clear_codex2autodl_history() -> Result<SshHistoryCleanup> {
    let mut cleanup = rewrite_codex2autodl_ssh_configs(None)?;
    for alias in &cleanup.removed_aliases {
        cleanup_alias_artifacts(alias)?;
    }
    let codex_cleanup = cleanup_codex_global_state(None, &cleanup.removed_aliases)?;
    cleanup
        .removed_codex_hosts
        .extend(codex_cleanup.removed_hosts);
    cleanup.backup_paths.extend(codex_cleanup.backup_paths);
    Ok(cleanup)
}

pub fn remove_codex2autodl_alias(alias: &str) -> Result<SshHistoryCleanup> {
    validate_alias(alias)?;
    cleanup_alias_artifacts(alias)?;
    let mut cleanup = rewrite_codex2autodl_ssh_configs(Some(alias))?;
    let codex_cleanup = cleanup_codex_global_state(Some(alias), &cleanup.removed_aliases)?;
    cleanup
        .removed_codex_hosts
        .extend(codex_cleanup.removed_hosts);
    cleanup.backup_paths.extend(codex_cleanup.backup_paths);
    Ok(cleanup)
}

pub fn cleanup_alias_artifacts(alias: &str) -> Result<()> {
    cleanup_alias_launch_agents(alias)?;

    let ssh_dir = home_dir()?.join(".ssh");
    let prefix = format!("codex2autodl-{alias}-proxy-");
    let Ok(entries) = fs::read_dir(&ssh_dir) else {
        return Ok(());
    };

    for entry in entries.flatten() {
        let file_name = entry.file_name();
        let file_name = file_name.to_string_lossy();
        if !file_name.starts_with(&prefix) {
            continue;
        }

        let path = entry.path();
        if file_name.ends_with(".watchdog.pid")
            && let Ok(pid) = fs::read_to_string(&path)
        {
            terminate_pid(pid.trim());
        }
        let _ = fs::remove_file(path);
    }

    Ok(())
}

pub fn cleanup_obsolete_tunnels(alias: &str, keep_remote_port: u16) -> Result<Vec<u16>> {
    validate_alias(alias)?;
    let ports = managed_tunnel_ports(alias)?;
    let mut removed = Vec::new();

    for port in ports {
        if port == keep_remote_port {
            continue;
        }
        stop_managed_tunnel(alias, port)?;
        removed.push(port);
    }

    Ok(removed)
}

fn managed_tunnel_ports(alias: &str) -> Result<BTreeSet<u16>> {
    let home = home_dir()?;
    let mut ports = BTreeSet::new();

    for dir in [home.join(".ssh"), home.join("Library/LaunchAgents")] {
        let Ok(entries) = fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let file_name = entry.file_name();
            let file_name = file_name.to_string_lossy();
            if let Some(port) = tunnel_artifact_remote_port(&file_name, alias) {
                ports.insert(port);
            }
        }
    }

    Ok(ports)
}

fn stop_managed_tunnel(alias: &str, remote_port: u16) -> Result<()> {
    let home = home_dir()?;
    let launch_agent = home.join(format!(
        "Library/LaunchAgents/codex2autodl-{alias}-proxy-{remote_port}.plist"
    ));
    bootout_launch_agent(
        &launch_agent,
        &proxy_tunnel_launchd_label(alias, &remote_port.to_string()),
    );

    let ssh_dir = home.join(".ssh");
    let pid_path = ssh_dir.join(format!(
        "codex2autodl-{alias}-proxy-{remote_port}.watchdog.pid"
    ));
    if let Ok(pid) = fs::read_to_string(&pid_path) {
        terminate_pid(pid.trim());
    }

    let control_path = ssh_dir.join(format!("codex2autodl-{alias}-proxy-{remote_port}.sock"));
    if control_path.exists() {
        let mut command = Command::new(SSH_BIN);
        command
            .arg("-S")
            .arg(&control_path)
            .args(["-O", "exit", alias])
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let _ = command_succeeds_with_timeout(command, Duration::from_millis(250));
    }

    if let Ok(entries) = fs::read_dir(&ssh_dir) {
        for entry in entries.flatten() {
            let file_name = entry.file_name();
            let file_name = file_name.to_string_lossy();
            if tunnel_artifact_remote_port(&file_name, alias) == Some(remote_port) {
                let _ = fs::remove_file(entry.path());
            }
        }
    }
    let _ = fs::remove_file(launch_agent);
    Ok(())
}

fn cleanup_alias_launch_agents(alias: &str) -> Result<()> {
    let launch_agents = home_dir()?.join("Library/LaunchAgents");
    let Ok(entries) = fs::read_dir(&launch_agents) else {
        return Ok(());
    };

    for entry in entries.flatten() {
        let file_name = entry.file_name();
        let file_name = file_name.to_string_lossy();
        let Some(remote_port) = launch_agent_remote_port(&file_name, alias) else {
            continue;
        };

        let path = entry.path();
        bootout_launch_agent(&path, &proxy_tunnel_launchd_label(alias, remote_port));
        let _ = fs::remove_file(path);
    }

    Ok(())
}

fn launch_agent_remote_port<'a>(file_name: &'a str, alias: &str) -> Option<&'a str> {
    let prefix = format!("codex2autodl-{alias}-proxy-");
    let remote_port = file_name.strip_prefix(&prefix)?.strip_suffix(".plist")?;
    if !remote_port.is_empty() && remote_port.chars().all(|c| c.is_ascii_digit()) {
        Some(remote_port)
    } else {
        None
    }
}

fn tunnel_artifact_remote_port(file_name: &str, alias: &str) -> Option<u16> {
    let prefix = format!("codex2autodl-{alias}-proxy-");
    let suffix = file_name.strip_prefix(&prefix)?;
    suffix.split('.').next()?.parse().ok()
}

fn proxy_tunnel_launchd_label(alias: &str, remote_port: &str) -> String {
    format!("com.codex2autodl.tunnel.{alias}.proxy.{remote_port}")
}

fn launchd_domain() -> Option<String> {
    let output = Command::new(ID_BIN)
        .arg("-u")
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let uid = String::from_utf8(output.stdout).ok()?;
    let uid = uid.trim();
    if uid.is_empty() {
        None
    } else {
        Some(format!("gui/{uid}"))
    }
}

fn bootout_launch_agent(plist_path: &PathBuf, label: &str) {
    if let Some(domain) = launchd_domain() {
        let _ = Command::new(LAUNCHCTL_BIN)
            .arg("bootout")
            .arg(format!("{domain}/{label}"))
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        let _ = Command::new(LAUNCHCTL_BIN)
            .arg("bootout")
            .arg(&domain)
            .arg(plist_path)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }

    let _ = Command::new(LAUNCHCTL_BIN)
        .args(["unload", "-w"])
        .arg(plist_path)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn rewrite_codex2autodl_ssh_configs(remove_alias: Option<&str>) -> Result<SshHistoryCleanup> {
    let mut removed = BTreeSet::new();
    let mut backup_paths = Vec::new();

    for config_path in codex2autodl_ssh_config_paths()? {
        let cleanup = rewrite_codex2autodl_ssh_config_file(&config_path, remove_alias)?;
        removed.extend(cleanup.removed_aliases);
        backup_paths.extend(cleanup.backup_paths);
    }

    Ok(SshHistoryCleanup {
        removed_aliases: removed.into_iter().collect(),
        removed_codex_hosts: Vec::new(),
        backup_paths,
    })
}

fn codex2autodl_ssh_config_paths() -> Result<Vec<PathBuf>> {
    let ssh_dir = home_dir()?.join(".ssh");
    Ok(vec![
        ssh_dir.join("config"),
        ssh_dir.join("codex2autodl/config"),
    ])
}

fn rewrite_codex2autodl_ssh_config_file(
    config_path: &PathBuf,
    remove_alias: Option<&str>,
) -> Result<SshHistoryCleanup> {
    if !config_path.is_file() {
        return Ok(SshHistoryCleanup {
            removed_aliases: Vec::new(),
            removed_codex_hosts: Vec::new(),
            backup_paths: Vec::new(),
        });
    }

    let text = fs::read_to_string(config_path)
        .with_context(|| format!("failed to read SSH config: {}", config_path.display()))?;
    let lines = text.lines().collect::<Vec<_>>();
    let mut output = Vec::new();
    let mut removed = BTreeSet::new();
    let mut changed = false;
    let mut i = 0;

    while i < lines.len() {
        let trimmed = lines[i].trim();

        if let Some(alias) = reliability_alias(trimmed)
            && alias_matches(remove_alias, &alias)
        {
            removed.insert(alias);
            changed = true;
            i += 1;
            while i < lines.len()
                && !lines[i]
                    .trim()
                    .starts_with("# <<< codex2autodl ssh reliability:")
            {
                i += 1;
            }
            if i < lines.len() {
                i += 1;
            }
            continue;
        }

        if trimmed == "# Added by codex2autodl setup script" {
            let host_index = next_non_empty_line(&lines, i + 1);
            if let Some(host_index) = host_index
                && let Some(aliases) = host_aliases(lines[host_index])
                && aliases
                    .iter()
                    .any(|alias| alias_matches(remove_alias, alias))
            {
                for alias in aliases {
                    if alias_matches(remove_alias, &alias) {
                        removed.insert(alias);
                    }
                }
                changed = true;
                i = end_of_host_block(&lines, host_index + 1);
                continue;
            }
            if remove_alias.is_none() {
                changed = true;
                i += 1;
                continue;
            }
        }

        if let Some(aliases) = host_aliases(lines[i]) {
            let end = end_of_host_block(&lines, i + 1);
            let block = lines[i..end].join("\n");
            let is_codex2autodl_block =
                block.contains("autodl_codex") || block.contains("codex2autodl");
            if is_codex2autodl_block
                && aliases
                    .iter()
                    .any(|alias| alias_matches(remove_alias, alias))
            {
                for alias in aliases {
                    if alias_matches(remove_alias, &alias) {
                        removed.insert(alias);
                    }
                }
                changed = true;
                i = end;
                continue;
            }
        }

        output.push(lines[i].to_string());
        i += 1;
    }

    let removed_aliases = removed.into_iter().collect::<Vec<_>>();
    if !changed {
        return Ok(SshHistoryCleanup {
            removed_aliases,
            removed_codex_hosts: Vec::new(),
            backup_paths: Vec::new(),
        });
    }

    let backup_path = backup_ssh_config(config_path)?;
    let mut new_text = output.join("\n");
    if !new_text.is_empty() {
        new_text.push('\n');
    }
    let tmp_path = config_path.with_extension("config.codex2autodl.tmp");
    fs::write(&tmp_path, new_text)
        .with_context(|| format!("failed to write temp SSH config: {}", tmp_path.display()))?;
    fs::set_permissions(&tmp_path, fs::Permissions::from_mode(0o600)).ok();
    fs::rename(&tmp_path, config_path)
        .with_context(|| format!("failed to replace SSH config: {}", config_path.display()))?;

    Ok(SshHistoryCleanup {
        removed_aliases,
        removed_codex_hosts: Vec::new(),
        backup_paths: vec![backup_path.display().to_string()],
    })
}

#[derive(Default)]
struct CodexStateCleanup {
    removed_hosts: Vec<String>,
    backup_paths: Vec<String>,
}

fn cleanup_codex_global_state(
    remove_alias: Option<&str>,
    removed_aliases: &[String],
) -> Result<CodexStateCleanup> {
    let state_path = home_dir()?.join(".codex/.codex-global-state.json");
    if !state_path.is_file() {
        return Ok(CodexStateCleanup::default());
    }

    let text = fs::read_to_string(&state_path)
        .with_context(|| format!("failed to read Codex state: {}", state_path.display()))?;
    let mut state = serde_json::from_str::<Value>(&text)
        .with_context(|| format!("failed to parse Codex state: {}", state_path.display()))?;

    let mut aliases = removed_aliases.iter().cloned().collect::<BTreeSet<_>>();
    if let Some(alias) = remove_alias {
        aliases.insert(alias.to_string());
    }

    let hosts = collect_codex_hosts_to_remove(&state, remove_alias, &aliases);
    if hosts.is_empty() {
        return Ok(CodexStateCleanup::default());
    }

    let mut changed = false;
    let mut removed_project_ids = BTreeSet::new();
    changed |= remove_codex_remote_projects(&mut state, &hosts, &mut removed_project_ids);
    changed |= remove_codex_managed_remote_connections(&mut state, &hosts);
    changed |= remove_codex_host_keyed_maps(&mut state, &hosts);
    changed |= remove_host_string_array(&mut state, "host-id-remote-control-allowed", &hosts);
    changed |= clear_selected_codex_host(&mut state, "selected-remote-host-id", &hosts);
    changed |= remove_project_id_array(&mut state, "project-order", &removed_project_ids);
    changed |= remove_project_id_array(&mut state, "pinned-project-ids", &removed_project_ids);

    if let Some(atom_state) = state.get_mut("electron-persisted-atom-state") {
        changed |= remove_codex_managed_remote_connections(atom_state, &hosts);
        changed |= remove_codex_host_keyed_maps(atom_state, &hosts);
        changed |= remove_host_string_array(atom_state, "host-id-remote-control-allowed", &hosts);
        changed |= clear_selected_codex_host(atom_state, "selected-remote-host-id", &hosts);
    }

    if !changed {
        return Ok(CodexStateCleanup::default());
    }

    let backup_path = backup_codex_state(&state_path)?;
    let tmp_path = state_path.with_extension("json.tmp-codex2autodl");
    let new_text = serde_json::to_string_pretty(&state)?;
    fs::write(&tmp_path, new_text)
        .with_context(|| format!("failed to write temp Codex state: {}", tmp_path.display()))?;
    fs::set_permissions(&tmp_path, fs::Permissions::from_mode(0o600)).ok();
    fs::rename(&tmp_path, &state_path)
        .with_context(|| format!("failed to replace Codex state: {}", state_path.display()))?;

    Ok(CodexStateCleanup {
        removed_hosts: hosts.into_iter().collect(),
        backup_paths: vec![backup_path.display().to_string()],
    })
}

fn collect_codex_hosts_to_remove(
    state: &Value,
    remove_alias: Option<&str>,
    aliases: &BTreeSet<String>,
) -> BTreeSet<String> {
    let mut hosts = BTreeSet::new();

    for alias in aliases {
        hosts.insert(format!("remote-ssh-discovered:{alias}"));
        hosts.insert(format!("remote-ssh-codex-managed:{alias}"));
    }

    collect_hosts_from_remote_projects(state, remove_alias, aliases, &mut hosts);
    collect_hosts_from_maps(state, remove_alias, aliases, &mut hosts);
    if let Some(atom_state) = state.get("electron-persisted-atom-state") {
        collect_hosts_from_maps(atom_state, remove_alias, aliases, &mut hosts);
    }

    hosts
}

fn collect_hosts_from_remote_projects(
    state: &Value,
    remove_alias: Option<&str>,
    aliases: &BTreeSet<String>,
    hosts: &mut BTreeSet<String>,
) {
    let Some(projects) = state.get("remote-projects").and_then(Value::as_array) else {
        return;
    };

    for project in projects {
        let Some(host_id) = project.get("hostId").and_then(Value::as_str) else {
            continue;
        };
        if should_remove_codex_host(host_id, remove_alias, aliases, Some(project)) {
            hosts.insert(host_id.to_string());
        }
    }
}

fn collect_hosts_from_maps(
    state: &Value,
    remove_alias: Option<&str>,
    aliases: &BTreeSet<String>,
    hosts: &mut BTreeSet<String>,
) {
    for field in CODEX_HOST_KEYED_MAPS {
        let Some(map) = state.get(field).and_then(Value::as_object) else {
            continue;
        };
        for host_id in map.keys() {
            if should_remove_codex_host(host_id, remove_alias, aliases, None) {
                hosts.insert(host_id.to_string());
            }
        }
    }
}

fn should_remove_codex_host(
    host_id: &str,
    remove_alias: Option<&str>,
    aliases: &BTreeSet<String>,
    project: Option<&Value>,
) -> bool {
    if !host_id.starts_with("remote-ssh-") {
        return false;
    }
    if let Some(alias) = remove_alias {
        return host_id_matches_alias(host_id, alias);
    }
    if aliases
        .iter()
        .any(|alias| host_id_matches_alias(host_id, alias))
    {
        return true;
    }
    project.is_some_and(is_autodl_remote_project) || remove_alias.is_none()
}

fn host_id_matches_alias(host_id: &str, alias: &str) -> bool {
    host_id
        .rsplit_once(':')
        .is_some_and(|(_, suffix)| suffix == alias)
}

fn is_autodl_remote_project(project: &Value) -> bool {
    project
        .get("remotePath")
        .and_then(Value::as_str)
        .is_some_and(|path| path.contains("/autodl-tmp"))
}

fn remove_codex_remote_projects(
    state: &mut Value,
    hosts: &BTreeSet<String>,
    removed_project_ids: &mut BTreeSet<String>,
) -> bool {
    let Some(projects) = state
        .get_mut("remote-projects")
        .and_then(Value::as_array_mut)
    else {
        return false;
    };
    let before = projects.len();
    projects.retain(|project| {
        let remove = project
            .get("hostId")
            .and_then(Value::as_str)
            .is_some_and(|host_id| hosts.contains(host_id));
        if remove && let Some(id) = project.get("id").and_then(Value::as_str) {
            removed_project_ids.insert(id.to_string());
        }
        !remove
    });
    before != projects.len()
}

fn remove_codex_managed_remote_connections(state: &mut Value, hosts: &BTreeSet<String>) -> bool {
    let Some(items) = state
        .get_mut("codex-managed-remote-connections")
        .and_then(Value::as_array_mut)
    else {
        return false;
    };
    let before = items.len();
    items.retain(|item| {
        item.get("hostId")
            .and_then(Value::as_str)
            .is_none_or(|host_id| !hosts.contains(host_id))
    });
    before != items.len()
}

fn remove_host_keyed_map(state: &mut Value, field: &str, hosts: &BTreeSet<String>) -> bool {
    let Some(map) = state.get_mut(field).and_then(Value::as_object_mut) else {
        return false;
    };
    let before = map.len();
    map.retain(|host_id, _| !hosts.contains(host_id));
    before != map.len()
}

fn remove_codex_host_keyed_maps(state: &mut Value, hosts: &BTreeSet<String>) -> bool {
    CODEX_HOST_KEYED_MAPS.iter().fold(false, |changed, field| {
        remove_host_keyed_map(state, field, hosts) || changed
    })
}

fn remove_host_string_array(state: &mut Value, field: &str, hosts: &BTreeSet<String>) -> bool {
    let Some(items) = state.get_mut(field).and_then(Value::as_array_mut) else {
        return false;
    };
    let before = items.len();
    items.retain(|item| item.as_str().is_none_or(|host_id| !hosts.contains(host_id)));
    before != items.len()
}

fn remove_project_id_array(state: &mut Value, field: &str, project_ids: &BTreeSet<String>) -> bool {
    let Some(items) = state.get_mut(field).and_then(Value::as_array_mut) else {
        return false;
    };
    let before = items.len();
    items.retain(|item| {
        item.as_str()
            .is_none_or(|project_id| !project_ids.contains(project_id))
    });
    before != items.len()
}

fn clear_selected_codex_host(state: &mut Value, field: &str, hosts: &BTreeSet<String>) -> bool {
    let Some(value) = state.get_mut(field) else {
        return false;
    };
    let should_clear = value
        .as_str()
        .is_some_and(|host_id| hosts.contains(host_id));
    if should_clear {
        *value = Value::Null;
    }
    should_clear
}

fn reliability_alias(line: &str) -> Option<String> {
    const PREFIX: &str = "# >>> codex2autodl ssh reliability: ";
    const SUFFIX: &str = " >>>";
    line.strip_prefix(PREFIX)
        .and_then(|value| value.strip_suffix(SUFFIX))
        .map(str::to_string)
}

fn alias_matches(remove_alias: Option<&str>, alias: &str) -> bool {
    remove_alias.is_none_or(|target| target == alias)
}

fn next_non_empty_line(lines: &[&str], start: usize) -> Option<usize> {
    (start..lines.len()).find(|index| !lines[*index].trim().is_empty())
}

fn host_aliases(line: &str) -> Option<Vec<String>> {
    let mut parts = line.split_whitespace();
    let keyword = parts.next()?;
    if !keyword.eq_ignore_ascii_case("Host") {
        return None;
    }
    let aliases = parts.map(str::to_string).collect::<Vec<_>>();
    if aliases.is_empty() {
        None
    } else {
        Some(aliases)
    }
}

fn end_of_host_block(lines: &[&str], start: usize) -> usize {
    let mut index = start;
    while index < lines.len() {
        let trimmed = lines[index].trim();
        if trimmed == "# Added by codex2autodl setup script"
            || trimmed.starts_with("# >>> codex2autodl ssh reliability:")
            || host_aliases(lines[index]).is_some()
        {
            break;
        }
        index += 1;
    }
    index
}

fn backup_ssh_config(config_path: &PathBuf) -> Result<PathBuf> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    let backup_path = config_path.with_file_name(format!("config.codex2autodl-backup-{timestamp}"));
    fs::copy(config_path, &backup_path).with_context(|| {
        format!(
            "failed to create SSH config backup: {}",
            backup_path.display()
        )
    })?;
    fs::set_permissions(&backup_path, fs::Permissions::from_mode(0o600)).ok();
    Ok(backup_path)
}

fn backup_codex_state(state_path: &PathBuf) -> Result<PathBuf> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    let file_name = state_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(".codex-global-state.json");
    let backup_path =
        state_path.with_file_name(format!("{file_name}.codex2autodl-backup-{timestamp}"));
    fs::copy(state_path, &backup_path).with_context(|| {
        format!(
            "failed to create Codex state backup: {}",
            backup_path.display()
        )
    })?;
    fs::set_permissions(&backup_path, fs::Permissions::from_mode(0o600)).ok();
    Ok(backup_path)
}

fn terminate_pid(pid: &str) {
    if pid.is_empty() || !pid.chars().all(|c| c.is_ascii_digit()) {
        return;
    }
    let _ = Command::new("kill")
        .arg(pid)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

pub fn import_managed_ssh_hosts() -> Vec<ImportedSshHost> {
    let Ok(home) = home_dir() else {
        return Vec::new();
    };
    let config = home.join(".ssh/config");
    let Ok(text) = fs::read_to_string(config) else {
        return Vec::new();
    };

    let mut imported = Vec::new();
    let mut managed = false;
    let mut alias = String::new();
    let mut user = String::new();
    let mut host = String::new();
    let mut port = String::new();

    let flush = |imported: &mut Vec<ImportedSshHost>,
                 managed: &mut bool,
                 alias: &mut String,
                 user: &mut String,
                 host: &mut String,
                 port: &mut String| {
        if *managed && !alias.is_empty() && !host.is_empty() {
            imported.push(ImportedSshHost {
                alias: std::mem::take(alias),
                user: if user.is_empty() {
                    "root".to_string()
                } else {
                    std::mem::take(user)
                },
                host: std::mem::take(host),
                port: port.parse().unwrap_or(22),
            });
        }
        *managed = false;
        alias.clear();
        user.clear();
        host.clear();
        port.clear();
    };

    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed == "# Added by codex2autodl setup script" {
            flush(
                &mut imported,
                &mut managed,
                &mut alias,
                &mut user,
                &mut host,
                &mut port,
            );
            managed = true;
            continue;
        }

        let mut parts = trimmed.split_whitespace();
        let Some(key) = parts.next() else {
            continue;
        };
        let value = parts.next().unwrap_or_default();

        if key.eq_ignore_ascii_case("Host") {
            if managed && alias.is_empty() {
                alias = value.to_string();
            } else {
                flush(
                    &mut imported,
                    &mut managed,
                    &mut alias,
                    &mut user,
                    &mut host,
                    &mut port,
                );
            }
        } else if managed && key.eq_ignore_ascii_case("HostName") {
            host = value.to_string();
        } else if managed && key.eq_ignore_ascii_case("User") {
            user = value.to_string();
        } else if managed && key.eq_ignore_ascii_case("Port") {
            port = value.to_string();
        }
    }

    flush(
        &mut imported,
        &mut managed,
        &mut alias,
        &mut user,
        &mut host,
        &mut port,
    );
    imported
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_ssh_command_standard() {
        let target = parse_ssh_command("ssh -p 2222 alice@host.example.com").unwrap();
        assert_eq!(target.user, "alice");
        assert_eq!(target.host, "host.example.com");
        assert_eq!(target.port, 2222);
    }

    #[test]
    fn parse_ssh_command_compact_port() {
        let target = parse_ssh_command("ssh -p2200 root@1.2.3.4").unwrap();
        assert_eq!(target.port, 2200);
        assert_eq!(target.host, "1.2.3.4");
    }

    #[test]
    fn parse_ssh_command_default_user_and_port() {
        let target = parse_ssh_command("ssh myhost").unwrap();
        assert_eq!(target.user, "root");
        assert_eq!(target.host, "myhost");
        assert_eq!(target.port, 22);
    }

    #[test]
    fn parse_ssh_command_dash_l_user() {
        let target = parse_ssh_command("ssh -l bob -p 22 host").unwrap();
        assert_eq!(target.user, "bob");
        assert_eq!(target.host, "host");
    }

    #[test]
    fn parse_ssh_command_skips_option_values() {
        let target =
            parse_ssh_command("ssh -i /tmp/key -o StrictHostKeyChecking=no user@host").unwrap();
        assert_eq!(target.user, "user");
        assert_eq!(target.host, "host");
    }

    #[test]
    fn parse_ssh_command_rejects_non_ssh() {
        assert!(parse_ssh_command("scp file host:/tmp").is_err());
    }

    #[test]
    fn parse_ssh_command_rejects_missing_host() {
        assert!(parse_ssh_command("ssh -p 22").is_err());
    }

    #[test]
    fn parse_ssh_command_rejects_non_numeric_port() {
        assert!(parse_ssh_command("ssh -p abc host").is_err());
    }

    #[test]
    fn validate_alias_accepts_valid() {
        assert!(validate_alias("connect9").is_ok());
        assert!(validate_alias("my-box_1.a").is_ok());
    }

    #[test]
    fn validate_alias_rejects_invalid() {
        assert!(validate_alias("").is_err());
        assert!(validate_alias("-leading-dash").is_err());
        assert!(validate_alias("has space").is_err());
        assert!(validate_alias("bad/slash").is_err());
    }

    #[test]
    fn launch_agent_remote_port_matches_exact_alias() {
        assert_eq!(
            launch_agent_remote_port("codex2autodl-box-proxy-8080.plist", "box"),
            Some("8080")
        );
        assert_eq!(
            launch_agent_remote_port("codex2autodl-box.extra-proxy-8080.plist", "box"),
            None
        );
        assert_eq!(
            launch_agent_remote_port("codex2autodl-box-proxy-api.plist", "box"),
            None
        );
    }

    #[test]
    fn tunnel_artifact_remote_port_matches_all_managed_files() {
        assert_eq!(
            tunnel_artifact_remote_port("codex2autodl-suidao-proxy-18890.watchdog.log.1", "suidao"),
            Some(18890)
        );
        assert_eq!(
            tunnel_artifact_remote_port("codex2autodl-suidao-proxy-8080.sock", "suidao"),
            Some(8080)
        );
        assert_eq!(
            tunnel_artifact_remote_port("codex2autodl-suidao2-proxy-8080.sock", "suidao"),
            None
        );
        assert_eq!(
            tunnel_artifact_remote_port("codex2autodl-suidao-proxy-api.sock", "suidao"),
            None
        );
    }

    #[test]
    fn proxy_tunnel_launchd_label_matches_setup_script() {
        assert_eq!(
            proxy_tunnel_launchd_label("ccccc", "8080"),
            "com.codex2autodl.tunnel.ccccc.proxy.8080"
        );
    }
}
