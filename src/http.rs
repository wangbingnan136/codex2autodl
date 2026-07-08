use crate::paths::ProjectPaths;
use crate::profile::{ProfileStatus, ProfileStore, SaveProfileRequest};
use crate::runner::{self, JobAction, JobContext, JobEventKind, JobStatus, JobStore};
use anyhow::Result;
use axum::extract::{Path, State};
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use axum::{Json, Router};
use serde::Serialize;
use std::convert::Infallible;
use std::net::SocketAddr;
use tokio_stream::StreamExt;

const INDEX_HTML: &str = include_str!("static/index.html");
const APP_CSS: &str = include_str!("static/app.css");
const APP_JS: &str = include_str!("static/app.js");

#[derive(Clone)]
pub struct AppState {
    paths: ProjectPaths,
    profiles: ProfileStore,
    jobs: JobStore,
}

#[derive(Serialize)]
struct ApiError {
    error: String,
}

#[derive(Serialize)]
struct ProfilesResponse {
    profiles: Vec<crate::profile::ProfileView>,
    data_dir: String,
}

impl AppState {
    pub fn new(paths: ProjectPaths) -> Result<Self> {
        let profiles = ProfileStore::load(&paths)?;
        let job_log_dir = paths.data_dir.join("job-logs");
        let jobs_dir = paths.data_dir.join("jobs");
        Ok(Self {
            paths,
            profiles,
            jobs: JobStore::new(job_log_dir, jobs_dir),
        })
    }

    fn job_context(&self) -> JobContext {
        JobContext {
            paths: self.paths.clone(),
            profiles: self.profiles.clone(),
            jobs: self.jobs.clone(),
        }
    }
}

pub async fn serve(state: AppState, addr: SocketAddr, health_interval: u64) -> Result<()> {
    let app = Router::new()
        .route("/", get(index))
        .route("/assets/app.css", get(css))
        .route("/assets/app.js", get(js))
        .route("/api/profiles", get(list_profiles).post(save_profile))
        .route("/api/profiles/{alias}", delete(delete_profile))
        .route("/api/profiles/{alias}/connect", post(connect_profile))
        .route("/api/profiles/{alias}/repair", post(repair_profile))
        .route("/api/profiles/{alias}/diagnose", post(diagnose_profile))
        .route("/api/profiles/{alias}/stop", post(stop_profile))
        .route("/api/active-remotes/repair", post(repair_active_remotes))
        .route("/api/jobs/{id}", get(get_job))
        .route("/api/jobs/{id}/stream", get(stream_job))
        .with_state(state.clone());

    if health_interval > 0 {
        spawn_health_watchdog(state, health_interval);
    } else {
        println!("codex2autodl health watchdog disabled (--health-interval 0)");
    }

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

/// 后台健康巡检:周期性检查所有 profile 的隧道状态,发现 Stale/Missing
/// 且当前无同名 running job 时,自动触发一次 RepairActive 修复所有活跃 alias。
fn spawn_health_watchdog(state: AppState, interval_secs: u64) {
    println!("codex2autodl health watchdog enabled (interval {interval_secs}s)");
    tokio::spawn(async move {
        let mut ticker =
            tokio::time::interval(std::time::Duration::from_secs(interval_secs.max(1)));
        // 跳过启动瞬间的第一次立即触发,给隧道一点建立时间。
        ticker.tick().await;
        loop {
            ticker.tick().await;
            // SSH 探测会阻塞,放到 blocking 线程池,避免卡住异步运行时。
            let profiles = state.profiles.clone();
            let unhealthy = tokio::task::spawn_blocking(move || profiles.has_unhealthy_tunnel())
                .await
                .unwrap_or(false);
            if unhealthy {
                // 已有活跃巡检 job 时,create_or_get_running 会去重,不会叠加。
                start_global_job(
                    state.clone(),
                    "active-remotes".to_string(),
                    JobAction::RepairActive,
                );
            }
        }
    });
}

async fn index() -> Response {
    with_content_type(INDEX_HTML, "text/html; charset=utf-8")
}

async fn css() -> Response {
    with_content_type(APP_CSS, "text/css; charset=utf-8")
}

async fn js() -> Response {
    with_content_type(APP_JS, "text/javascript; charset=utf-8")
}

async fn list_profiles(State(state): State<AppState>) -> Json<ProfilesResponse> {
    Json(ProfilesResponse {
        profiles: state.profiles.list_views(),
        data_dir: state.paths.data_dir.display().to_string(),
    })
}

async fn save_profile(
    State(state): State<AppState>,
    Json(request): Json<SaveProfileRequest>,
) -> Response {
    match state.profiles.save(request) {
        Ok(profile) => (StatusCode::OK, Json(profile)).into_response(),
        Err(err) => api_error(StatusCode::BAD_REQUEST, err),
    }
}

async fn delete_profile(State(state): State<AppState>, Path(alias): Path<String>) -> Response {
    match state.profiles.remove(&alias) {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(err) => api_error(StatusCode::BAD_REQUEST, err),
    }
}

async fn connect_profile(State(state): State<AppState>, Path(alias): Path<String>) -> Response {
    start_job(state, alias, JobAction::Connect)
}

async fn repair_profile(State(state): State<AppState>, Path(alias): Path<String>) -> Response {
    start_job(state, alias, JobAction::QuickReconnect)
}

async fn diagnose_profile(State(state): State<AppState>, Path(alias): Path<String>) -> Response {
    start_job(state, alias, JobAction::Diagnose)
}

async fn stop_profile(State(state): State<AppState>, Path(alias): Path<String>) -> Response {
    start_job(state, alias, JobAction::StopTunnel)
}

async fn repair_active_remotes(State(state): State<AppState>) -> Response {
    start_global_job(state, "active-remotes".to_string(), JobAction::RepairActive)
}

async fn get_job(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    match state.jobs.get(&id) {
        Some(job) => Json(job).into_response(),
        None => api_error(StatusCode::NOT_FOUND, anyhow::anyhow!("job not found")),
    }
}

/// SSE 端点:先补发该 job 已有日志快照,再持续推送增量,job 终态时发送
/// `done` 事件并结束流。每条日志作为一个 `log` 事件,状态收尾为 `done` 事件。
async fn stream_job(State(state): State<AppState>, Path(id): Path<String>) -> Response {
    let Some(snapshot) = state.jobs.get(&id) else {
        return api_error(StatusCode::NOT_FOUND, anyhow::anyhow!("job not found"));
    };

    // 订阅要在读取快照之前建立,避免快照与订阅之间丢事件;这里顺序为
    // subscribe -> 取快照,快照里已有的行照常补发,少量重复由前端按序容忍。
    let receiver = state.jobs.subscribe();
    let already_terminal = snapshot.status != JobStatus::Running;

    // 起始事件:补发已有日志 + 当前状态。
    let initial_logs = snapshot.logs.clone();
    let initial_stream = tokio_stream::iter(
        initial_logs
            .into_iter()
            .map(|line| Ok::<Event, Infallible>(Event::default().event("log").data(line)))
            .collect::<Vec<_>>(),
    );

    let target_id = id.clone();
    let live_stream = tokio_stream::wrappers::BroadcastStream::new(receiver).filter_map(
        move |event| match event {
            Ok(event) if event.job_id == target_id => match event.kind {
                JobEventKind::Log(line) => Some(Ok::<Event, Infallible>(
                    Event::default().event("log").data(line),
                )),
                JobEventKind::Finished(status) => {
                    Some(Ok(Event::default().event("done").data(status_str(&status))))
                }
            },
            _ => None,
        },
    );

    let stream: std::pin::Pin<
        Box<dyn tokio_stream::Stream<Item = Result<Event, Infallible>> + Send>,
    > = if already_terminal {
        // 已经结束的 job:补发日志后立即发 done。
        Box::pin(
            initial_stream.chain(tokio_stream::iter(vec![Ok(Event::default()
                .event("done")
                .data(status_str(&snapshot.status)))])),
        )
    } else {
        Box::pin(initial_stream.chain(live_stream))
    };

    Sse::new(stream)
        .keep_alive(KeepAlive::default())
        .into_response()
}

fn status_str(status: &JobStatus) -> &'static str {
    match status {
        JobStatus::Running => "running",
        JobStatus::Succeeded => "succeeded",
        JobStatus::Failed => "failed",
    }
}

fn start_global_job(state: AppState, alias: String, action: JobAction) -> Response {
    let (job, already_running) = state.jobs.create_or_get_running(&alias, action);
    if already_running {
        return (StatusCode::OK, Json(job)).into_response();
    }

    let ctx = state.job_context();
    let job_id = job.id.clone();
    tokio::spawn(async move {
        runner::run_job(ctx, job_id, alias, action).await;
    });

    (StatusCode::ACCEPTED, Json(job)).into_response()
}

fn start_job(state: AppState, alias: String, action: JobAction) -> Response {
    if state.profiles.get(&alias).is_none() {
        return api_error(StatusCode::NOT_FOUND, anyhow::anyhow!("profile not found"));
    }

    let (job, already_running) = state.jobs.create_or_get_running(&alias, action);
    if already_running {
        return (StatusCode::OK, Json(job)).into_response();
    }

    let running_message = match action {
        JobAction::Connect => "连接中",
        JobAction::QuickReconnect => "修复隧道中",
        JobAction::RepairActive => "修复活跃连接中",
        JobAction::Diagnose => "诊断中",
        JobAction::StopTunnel => "停止隧道中",
    };
    if let Err(err) = state
        .profiles
        .mark_status(&alias, ProfileStatus::Running, running_message)
    {
        return api_error(StatusCode::BAD_REQUEST, err);
    }

    let ctx = state.job_context();
    let job_id = job.id.clone();
    tokio::spawn(async move {
        runner::run_job(ctx, job_id, alias, action).await;
    });

    (StatusCode::ACCEPTED, Json(job)).into_response()
}

fn with_content_type(body: &'static str, content_type: &'static str) -> Response {
    let mut response = body.into_response();
    response
        .headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static(content_type));
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-store, max-age=0"),
    );
    response
}

fn api_error(status: StatusCode, err: anyhow::Error) -> Response {
    (
        status,
        Json(ApiError {
            error: err.to_string(),
        }),
    )
        .into_response()
}
