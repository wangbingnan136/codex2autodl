use crate::paths::ProjectPaths;
use crate::profile::{ProfileStatus, ProfileStore, SaveProfileRequest};
use crate::runner::{self, JobAction, JobContext, JobStore};
use anyhow::Result;
use axum::extract::{Path, State};
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post};
use axum::{Json, Router};
use serde::Serialize;
use std::net::SocketAddr;

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
        Ok(Self {
            paths,
            profiles,
            jobs: JobStore::new(job_log_dir),
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

pub async fn serve(state: AppState, addr: SocketAddr) -> Result<()> {
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
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
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
