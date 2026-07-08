use anyhow::{Context, Result};
use std::path::PathBuf;

#[derive(Clone, Debug)]
pub struct ProjectPaths {
    pub project_root: PathBuf,
    pub data_dir: PathBuf,
    pub profiles_file: PathBuf,
    pub setup_script: PathBuf,
}

impl ProjectPaths {
    pub fn discover() -> Result<Self> {
        let project_root = discover_project_root()?;
        let setup_script = project_root.join("scripts/setup-autodl-codex.sh");
        let data_dir = data_dir()?;
        std::fs::create_dir_all(&data_dir)
            .with_context(|| format!("failed to create data dir: {}", data_dir.display()))?;

        Ok(Self {
            project_root,
            profiles_file: data_dir.join("profiles.json"),
            data_dir,
            setup_script,
        })
    }
}

fn discover_project_root() -> Result<PathBuf> {
    let cwd = std::env::current_dir().context("failed to read current directory")?;
    if cwd.join("scripts/setup-autodl-codex.sh").is_file() {
        return Ok(cwd);
    }

    let exe = std::env::current_exe().context("failed to locate executable")?;
    for ancestor in exe.ancestors() {
        let direct = ancestor.join("scripts/setup-autodl-codex.sh");
        if direct.is_file() {
            return Ok(ancestor.to_path_buf());
        }

        let resources = ancestor.join("Resources");
        if resources.join("scripts/setup-autodl-codex.sh").is_file() {
            return Ok(resources);
        }
    }

    Ok(cwd)
}

fn data_dir() -> Result<PathBuf> {
    if let Ok(value) = std::env::var("CODEX2AUTODL_HOME") {
        if !value.trim().is_empty() {
            return Ok(PathBuf::from(value));
        }
    }

    Ok(home_dir()?.join(".codex2autodl"))
}

pub fn home_dir() -> Result<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME is not set")
}
