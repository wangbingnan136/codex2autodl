use crate::paths::ProjectPaths;
use crate::profile::{Profile, ProfileStatus, ProfileStore, now_string};
use crate::secrets::{self, SecretKind};
use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncRead, BufReader};
use tokio::process::Command;

/// 内存与磁盘各自保留的最大 job 数量;超出后淘汰最早的已完成 job。
const MAX_JOBS: usize = 200;

#[derive(Clone)]
pub struct JobStore {
    next_id: Arc<AtomicU64>,
    jobs: Arc<Mutex<BTreeMap<String, JobSnapshot>>>,
    log_dir: Arc<PathBuf>,
    jobs_dir: Arc<PathBuf>,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobAction {
    Connect,
    QuickReconnect,
    RepairActive,
    Diagnose,
    StopTunnel,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobStatus {
    Running,
    Succeeded,
    Failed,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JobSnapshot {
    pub id: String,
    pub alias: String,
    pub action: JobAction,
    pub status: JobStatus,
    pub started_at: String,
    pub finished_at: Option<String>,
    pub exit_code: Option<i32>,
    pub logs: Vec<String>,
    pub log_path: Option<String>,
}

#[derive(Clone)]
pub struct JobContext {
    pub paths: ProjectPaths,
    pub profiles: ProfileStore,
    pub jobs: JobStore,
}

impl JobStore {
    pub fn new(log_dir: PathBuf, jobs_dir: PathBuf) -> Self {
        fs::create_dir_all(&log_dir).ok();
        fs::create_dir_all(&jobs_dir).ok();

        let mut loaded = load_jobs_from_disk(&jobs_dir);
        // 面板重启后,磁盘上仍标记为 running 的 job 其实已随旧进程消亡,
        // 标记为 failed,避免留下"永久运行中"的幽灵任务。
        for job in loaded.values_mut() {
            if job.status == JobStatus::Running {
                job.status = JobStatus::Failed;
                job.finished_at = Some(now_string());
                job.logs.push(format!(
                    "{} 面板重启,任务中断",
                    job.finished_at.as_deref().unwrap_or("unknown-time")
                ));
                write_job_file(&jobs_dir, job);
            }
        }

        let next_id = loaded
            .keys()
            .filter_map(|id| id.strip_prefix("job-"))
            .filter_map(|n| n.parse::<u64>().ok())
            .max()
            .map(|max| max + 1)
            .unwrap_or(1);

        let store = Self {
            next_id: Arc::new(AtomicU64::new(next_id)),
            jobs: Arc::new(Mutex::new(loaded)),
            log_dir: Arc::new(log_dir),
            jobs_dir: Arc::new(jobs_dir),
        };
        // 加载后立即裁剪到上限。
        {
            let mut jobs = store.jobs.lock().expect("jobs lock poisoned");
            store.enforce_limits(&mut jobs);
        }
        store
    }

    pub fn create_or_get_running(&self, alias: &str, action: JobAction) -> (JobSnapshot, bool) {
        let mut jobs = self.jobs.lock().expect("jobs lock poisoned");
        if let Some(job) = jobs
            .values()
            .find(|job| job.alias == alias && job.status == JobStatus::Running)
            .cloned()
        {
            return (job, true);
        }

        let id = format!("job-{}", self.next_id.fetch_add(1, Ordering::Relaxed));
        let log_path = self.log_dir.join(format!(
            "{}-{}-{}.log",
            id,
            action.log_label(),
            safe_file_component(alias)
        ));
        let job = JobSnapshot {
            id: id.clone(),
            alias: alias.to_string(),
            action,
            status: JobStatus::Running,
            started_at: now_string(),
            finished_at: None,
            exit_code: None,
            logs: Vec::new(),
            log_path: Some(log_path.display().to_string()),
        };
        append_line_to_file(
            &log_path,
            &format!("{} codex2autodl job started", job.started_at),
        );
        write_job_file(&self.jobs_dir, &job);
        jobs.insert(id, job.clone());
        self.enforce_limits(&mut jobs);
        (job, false)
    }

    pub fn get(&self, id: &str) -> Option<JobSnapshot> {
        self.jobs
            .lock()
            .expect("jobs lock poisoned")
            .get(id)
            .cloned()
    }

    pub fn append(&self, id: &str, line: impl Into<String>) {
        let line = line.into();
        let mut jobs = self.jobs.lock().expect("jobs lock poisoned");
        if let Some(job) = jobs.get_mut(id) {
            if let Some(log_path) = job.log_path.as_deref() {
                append_line_to_file(Path::new(log_path), &line);
            }
            job.logs.push(line);
            if job.logs.len() > 1200 {
                let overflow = job.logs.len() - 1200;
                job.logs.drain(0..overflow);
            }
            write_job_file(&self.jobs_dir, job);
        }
    }

    pub fn finish(&self, id: &str, status: JobStatus, exit_code: Option<i32>) {
        let mut jobs = self.jobs.lock().expect("jobs lock poisoned");
        if let Some(job) = jobs.get_mut(id) {
            job.status = status;
            job.exit_code = exit_code;
            job.finished_at = Some(now_string());
            if let Some(log_path) = job.log_path.as_deref() {
                append_line_to_file(
                    Path::new(log_path),
                    &format!(
                        "{} codex2autodl job finished: {:?} exit={}",
                        job.finished_at.as_deref().unwrap_or("unknown-time"),
                        job.status,
                        exit_code
                            .map(|code| code.to_string())
                            .unwrap_or_else(|| "unknown".to_string())
                    ),
                );
            }
            write_job_file(&self.jobs_dir, job);
        }
        self.enforce_limits(&mut jobs);
    }

    /// 把内存与磁盘中的 job 都裁剪到 MAX_JOBS:优先淘汰最早的已完成 job,
    /// 正在运行的 job 永不淘汰。
    fn enforce_limits(&self, jobs: &mut BTreeMap<String, JobSnapshot>) {
        if jobs.len() <= MAX_JOBS {
            return;
        }
        // BTreeMap 按 id 字符串排序,不等于时间序;这里按 job 序号数值排序取最早的已完成项。
        let mut finished_ids = jobs
            .values()
            .filter(|job| job.status != JobStatus::Running)
            .map(|job| job.id.clone())
            .collect::<Vec<_>>();
        finished_ids.sort_by_key(|id| job_id_ordinal(id));

        let mut overflow = jobs.len().saturating_sub(MAX_JOBS);
        for id in finished_ids {
            if overflow == 0 {
                break;
            }
            jobs.remove(&id);
            remove_job_file(&self.jobs_dir, &id);
            overflow -= 1;
        }
    }
}

impl JobAction {
    fn log_label(self) -> &'static str {
        match self {
            Self::Connect => "connect",
            Self::QuickReconnect => "repair",
            Self::RepairActive => "repair-active",
            Self::Diagnose => "diagnose",
            Self::StopTunnel => "stop",
        }
    }
}

fn append_line_to_file(path: &Path, line: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).ok();
    }
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{line}");
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).ok();
}

fn safe_file_component(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-') {
                ch
            } else {
                '_'
            }
        })
        .collect()
}

/// 从 job 序号(job-N)提取数值,用于稳定的时间序排序;非法则视为 0。
fn job_id_ordinal(id: &str) -> u64 {
    id.strip_prefix("job-")
        .and_then(|n| n.parse::<u64>().ok())
        .unwrap_or(0)
}

fn job_file_path(jobs_dir: &Path, id: &str) -> PathBuf {
    jobs_dir.join(format!("{}.json", safe_file_component(id)))
}

/// 原子写入单个 job 快照(临时文件 + rename),权限 0o600。
fn write_job_file(jobs_dir: &Path, job: &JobSnapshot) {
    let Ok(text) = serde_json::to_string_pretty(job) else {
        return;
    };
    let final_path = job_file_path(jobs_dir, &job.id);
    let tmp_path = final_path.with_extension("json.tmp");
    if fs::create_dir_all(jobs_dir).is_err() {
        return;
    }
    if fs::write(&tmp_path, text).is_err() {
        return;
    }
    fs::set_permissions(&tmp_path, fs::Permissions::from_mode(0o600)).ok();
    let _ = fs::rename(&tmp_path, &final_path);
}

fn remove_job_file(jobs_dir: &Path, id: &str) {
    let _ = fs::remove_file(job_file_path(jobs_dir, id));
}

/// 从磁盘加载所有 job 快照到内存。损坏的文件跳过。
fn load_jobs_from_disk(jobs_dir: &Path) -> BTreeMap<String, JobSnapshot> {
    let mut jobs = BTreeMap::new();
    let Ok(entries) = fs::read_dir(jobs_dir) else {
        return jobs;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(text) = fs::read_to_string(&path) else {
            continue;
        };
        if let Ok(job) = serde_json::from_str::<JobSnapshot>(&text) {
            jobs.insert(job.id.clone(), job);
        }
    }
    jobs
}

pub async fn run_job(ctx: JobContext, job_id: String, alias: String, action: JobAction) {
    let result = run_job_inner(ctx.clone(), &job_id, &alias, action).await;
    match result {
        Ok(()) => {
            ctx.jobs.finish(&job_id, JobStatus::Succeeded, Some(0));
        }
        Err(err) => {
            ctx.jobs.append(&job_id, format!("Error: {err:#}"));
            ctx.jobs.finish(&job_id, JobStatus::Failed, None);
            let _ = ctx
                .profiles
                .mark_status(&alias, ProfileStatus::Failed, err.to_string());
        }
    }
}

async fn run_job_inner(
    ctx: JobContext,
    job_id: &str,
    alias: &str,
    action: JobAction,
) -> Result<()> {
    let profile = if matches!(action, JobAction::RepairActive) {
        None
    } else {
        Some(
            ctx.profiles
                .get(alias)
                .with_context(|| format!("profile not found: {alias}"))?,
        )
    };

    if profile.is_some() {
        ctx.profiles
            .mark_status(alias, ProfileStatus::Running, "任务运行中")?;
    }
    ctx.jobs
        .append(job_id, format!("codex2autodl {:?}: {}", action, alias));

    if !ctx.paths.setup_script.is_file() {
        return Err(anyhow!(
            "setup script not found: {}",
            ctx.paths.setup_script.display()
        ));
    }

    let mut temp_files = Vec::new();
    let args = match profile.as_ref() {
        Some(profile) => build_args(&ctx, profile, action, job_id, &mut temp_files)?,
        None => build_global_args(action),
    };

    ctx.jobs.append(
        job_id,
        format!(
            "Running: {} {}",
            ctx.paths.setup_script.display(),
            shell_join_for_log(&args)
        ),
    );

    let mut child = Command::new(&ctx.paths.setup_script)
        .args(&args)
        .current_dir(&ctx.paths.project_root)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .with_context(|| format!("failed to start {}", ctx.paths.setup_script.display()))?;

    let stdout = child.stdout.take().context("failed to capture stdout")?;
    let stderr = child.stderr.take().context("failed to capture stderr")?;
    let out_job = job_id.to_string();
    let err_job = job_id.to_string();
    let out_jobs = ctx.jobs.clone();
    let err_jobs = ctx.jobs.clone();
    let stdout_task = tokio::spawn(async move {
        pipe_lines(stdout, out_jobs, out_job, "").await;
    });
    let stderr_task = tokio::spawn(async move {
        pipe_lines(stderr, err_jobs, err_job, "stderr: ").await;
    });

    let status = child.wait().await.context("setup script wait failed")?;
    let _ = stdout_task.await;
    let _ = stderr_task.await;

    for file in temp_files {
        let _ = fs::remove_file(file);
    }

    let code = status.code();
        if status.success() {
            if matches!(action, JobAction::RepairActive) {
                ctx.jobs.finish(job_id, JobStatus::Succeeded, code);
                return Ok(());
            }
            let (profile_status, message) = match action {
                JobAction::Connect => (ProfileStatus::Connected, "连接完成"),
                JobAction::QuickReconnect => (ProfileStatus::Connected, "隧道已修复"),
                JobAction::RepairActive => unreachable!("handled above"),
                JobAction::Diagnose => (ProfileStatus::Connected, "诊断完成"),
                JobAction::StopTunnel => (ProfileStatus::Stopped, "隧道已停止"),
            };
        ctx.profiles.mark_status(alias, profile_status, message)?;
        ctx.jobs.finish(job_id, JobStatus::Succeeded, code);
        Ok(())
    } else {
        let message = format!("脚本退出码: {}", code.unwrap_or(-1));
        if profile.is_some() {
            ctx.profiles
                .mark_status(alias, ProfileStatus::Failed, message.clone())?;
        }
        ctx.jobs.finish(job_id, JobStatus::Failed, code);
        Err(anyhow!(message))
    }
}

fn build_global_args(action: JobAction) -> Vec<String> {
    match action {
        JobAction::RepairActive => vec![
            "--quick-reconnect-active".to_string(),
            "--local-api-port".to_string(),
            "8080".to_string(),
            "--diagnose".to_string(),
        ],
        _ => unreachable!("global args are only supported for global actions"),
    }
}

fn build_args(
    ctx: &JobContext,
    profile: &Profile,
    action: JobAction,
    job_id: &str,
    temp_files: &mut Vec<PathBuf>,
) -> Result<Vec<String>> {
    let mut args = vec!["--alias".to_string(), profile.alias.clone()];

    match action {
        JobAction::Connect => {
            if let Some(password) = secrets::get_secret(SecretKind::SshPassword, &profile.alias)? {
                let file = write_temp_secret(job_id, "ssh-password", &password)?;
                args.push("--ssh-password-file".to_string());
                args.push(file.display().to_string());
                temp_files.push(file);
            } else if !alias_accepts_key(&profile.alias) {
                return Err(anyhow!(
                    "没有保存 SSH 密码，且当前 alias 不能免密连接。请先编辑该服务器并保存密码。"
                ));
            }

            args.push("--local-api-port".to_string());
            args.push(port_spec(profile));

            if let Some(api_key) = secrets::get_secret(SecretKind::ApiKey, &profile.alias)? {
                let file = write_temp_secret(job_id, "api-key", &api_key)?;
                args.push("--api-key-file".to_string());
                args.push(file.display().to_string());
                temp_files.push(file);
            }

            args.push("--diagnose".to_string());
            args.push(profile.ssh_command.clone());
        }
        JobAction::QuickReconnect => {
            args.push("--quick-reconnect".to_string());
            args.push("--local-api-port".to_string());
            args.push(port_spec(profile));
        }
        JobAction::Diagnose => {
            args.push("--local-api-port".to_string());
            args.push(port_spec(profile));
            args.push("--diagnose".to_string());
        }
        JobAction::StopTunnel => {
            args.push("--stop-api-tunnel".to_string());
            args.push("--local-api-port".to_string());
            args.push(port_spec(profile));
        }
        JobAction::RepairActive => {
            unreachable!("RepairActive uses global args, not per-profile build_args")
        }
    }

    if !ctx.paths.setup_script.is_file() {
        return Err(anyhow!(
            "setup script not found: {}",
            ctx.paths.setup_script.display()
        ));
    }

    Ok(args)
}

fn port_spec(profile: &Profile) -> String {
    if profile.local_api_port == profile.remote_api_port {
        profile.local_api_port.to_string()
    } else {
        format!("{}:{}", profile.local_api_port, profile.remote_api_port)
    }
}

fn alias_accepts_key(alias: &str) -> bool {
    std::process::Command::new("ssh")
        .args([
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=5",
            alias,
            "echo CODEX2AUTODL_KEY_OK",
        ])
        .output()
        .is_ok_and(|output| {
            output.status.success()
                && String::from_utf8_lossy(&output.stdout).contains("CODEX2AUTODL_KEY_OK")
        })
}

fn write_temp_secret(job_id: &str, label: &str, value: &str) -> Result<PathBuf> {
    let path = std::env::temp_dir().join(format!("codex2autodl-{job_id}-{label}.secret"));
    fs::write(&path, format!("{value}\n"))
        .with_context(|| format!("failed to write temp secret: {}", path.display()))?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).ok();
    Ok(path)
}

async fn pipe_lines<R>(reader: R, jobs: JobStore, job_id: String, prefix: &'static str)
where
    R: AsyncRead + Unpin,
{
    let mut lines = BufReader::new(reader).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        jobs.append(&job_id, format!("{prefix}{line}"));
    }
}

fn shell_join_for_log(args: &[String]) -> String {
    args.iter()
        .map(|arg| {
            if arg.chars().all(|c| {
                c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/' | ':' | '=')
            }) {
                arg.clone()
            } else {
                format!("'{}'", arg.replace('\'', "'\\''"))
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}
