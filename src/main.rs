mod http;
mod paths;
mod profile;
mod runner;
mod secrets;
mod ssh;

use anyhow::{Context, Result, bail};
use paths::ProjectPaths;
use std::net::SocketAddr;
use std::process::Command;

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse()?;

    match cli.command {
        CommandKind::Serve { host, port, open } => {
            let paths = ProjectPaths::discover()?;
            let state = http::AppState::new(paths).context("failed to initialize app state")?;
            let addr: SocketAddr = format!("{host}:{port}")
                .parse()
                .with_context(|| format!("invalid listen address: {host}:{port}"))?;
            let url = format!("http://{addr}");

            if open {
                open_in_browser(&url);
            }

            println!("codex2autodl control panel: {url}");
            http::serve(state, addr).await
        }
        CommandKind::ClearAutodlHistory => {
            let cleanup = ssh::clear_codex2autodl_history()?;
            if cleanup.removed_aliases.is_empty() && cleanup.removed_codex_hosts.is_empty() {
                println!("No codex2autodl SSH connection history found.");
            } else {
                if !cleanup.removed_aliases.is_empty() {
                    println!(
                        "Removed {} codex2autodl SSH connection(s): {}",
                        cleanup.removed_aliases.len(),
                        cleanup.removed_aliases.join(", ")
                    );
                }
                if !cleanup.removed_codex_hosts.is_empty() {
                    println!(
                        "Removed {} Codex remote state entries: {}",
                        cleanup.removed_codex_hosts.len(),
                        cleanup.removed_codex_hosts.join(", ")
                    );
                }
                for path in cleanup.backup_paths {
                    println!("Backup: {path}");
                }
            }
            Ok(())
        }
        CommandKind::Help => {
            print_help();
            Ok(())
        }
    }
}

#[derive(Debug)]
struct Cli {
    command: CommandKind,
}

#[derive(Debug)]
enum CommandKind {
    Serve { host: String, port: u16, open: bool },
    ClearAutodlHistory,
    Help,
}

impl Cli {
    fn parse() -> Result<Self> {
        let mut args = std::env::args().skip(1).collect::<Vec<_>>();
        if args
            .first()
            .is_some_and(|arg| arg == "help" || arg == "--help" || arg == "-h")
        {
            return Ok(Self {
                command: CommandKind::Help,
            });
        }

        if args.first().is_none_or(|arg| arg.starts_with('-')) {
            args.insert(0, "serve".to_string());
        }

        let subcommand = args.remove(0);
        if matches!(
            subcommand.as_str(),
            "clear-autodl-history" | "clear-ssh-history"
        ) {
            return Ok(Self {
                command: CommandKind::ClearAutodlHistory,
            });
        }
        if subcommand != "serve" {
            bail!("unknown command: {subcommand}");
        }

        let mut host = "127.0.0.1".to_string();
        let mut port = 8765u16;
        let mut open = true;
        let mut i = 0;

        while i < args.len() {
            match args[i].as_str() {
                "--host" => {
                    i += 1;
                    host = args.get(i).cloned().context("--host requires a value")?;
                }
                "--port" => {
                    i += 1;
                    port = args
                        .get(i)
                        .context("--port requires a value")?
                        .parse()
                        .context("--port must be a number")?;
                }
                "--open" => open = true,
                "--no-open" => open = false,
                "--help" | "-h" => {
                    return Ok(Self {
                        command: CommandKind::Help,
                    });
                }
                value => bail!("unknown serve option: {value}"),
            }
            i += 1;
        }

        Ok(Self {
            command: CommandKind::Serve { host, port, open },
        })
    }
}

fn open_in_browser(url: &str) {
    #[cfg(target_os = "macos")]
    {
        let _ = Command::new("open").arg(url).spawn();
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = Command::new("xdg-open").arg(url).spawn();
    }
}

fn print_help() {
    println!(
        r#"codex2autodl

Usage:
  codex2autodl serve [--host 127.0.0.1] [--port 8765] [--open|--no-open]
  codex2autodl clear-autodl-history

The Rust control panel keeps server profiles in ~/.codex2autodl and stores
passwords/API keys in the operating system keychain.
"#
    );
}
