mod http;
mod local_codex;
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
        CommandKind::Serve {
            host,
            port,
            open,
            health_interval,
        } => {
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
            http::serve(state, addr, health_interval).await
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
    Serve {
        host: String,
        port: u16,
        open: bool,
        /// 健康巡检间隔(秒);0 表示关闭自动巡检。
        health_interval: u64,
    },
    ClearAutodlHistory,
    Help,
}

impl Cli {
    fn parse() -> Result<Self> {
        Self::parse_from(std::env::args().skip(1).collect())
    }

    fn parse_from(mut args: Vec<String>) -> Result<Self> {
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
        // 默认 60s;可被 CLI --health-interval 覆盖,其次是环境变量,0 表示关闭。
        let mut health_interval = default_health_interval();
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
                "--health-interval" => {
                    i += 1;
                    health_interval = args
                        .get(i)
                        .context("--health-interval requires a value")?
                        .parse()
                        .context("--health-interval must be a non-negative integer (seconds)")?;
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
            command: CommandKind::Serve {
                host,
                port,
                open,
                health_interval,
            },
        })
    }
}

/// 读取环境变量 CODEX2AUTODL_HEALTH_INTERVAL(秒),缺省或非法时回退到 60s。
fn default_health_interval() -> u64 {
    match std::env::var("CODEX2AUTODL_HEALTH_INTERVAL") {
        Ok(value) => value.trim().parse::<u64>().unwrap_or(60),
        Err(_) => 60,
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
  codex2autodl serve [--host 127.0.0.1] [--port 8765] [--open|--no-open] [--health-interval 60]
  codex2autodl clear-autodl-history

The Rust control panel keeps server profiles in ~/.codex2autodl and stores
passwords/API keys in the operating system keychain.

--health-interval <秒> 控制后台自动健康巡检的间隔;0 关闭。也可用环境变量
CODEX2AUTODL_HEALTH_INTERVAL 设置。巡检会自动修复掉线的 SSH 反向隧道。
"#
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn parse_defaults_to_serve() {
        let cli = Cli::parse_from(args(&[])).unwrap();
        match cli.command {
            CommandKind::Serve {
                host, port, open, ..
            } => {
                assert_eq!(host, "127.0.0.1");
                assert_eq!(port, 8765);
                assert!(open);
            }
            other => panic!("expected serve, got {other:?}"),
        }
    }

    #[test]
    fn parse_serve_flags() {
        let cli = Cli::parse_from(args(&[
            "serve",
            "--host",
            "0.0.0.0",
            "--port",
            "9000",
            "--no-open",
        ]))
        .unwrap();
        match cli.command {
            CommandKind::Serve {
                host, port, open, ..
            } => {
                assert_eq!(host, "0.0.0.0");
                assert_eq!(port, 9000);
                assert!(!open);
            }
            other => panic!("expected serve, got {other:?}"),
        }
    }

    #[test]
    fn parse_health_interval_flag() {
        let cli = Cli::parse_from(args(&["serve", "--health-interval", "15"])).unwrap();
        match cli.command {
            CommandKind::Serve {
                health_interval, ..
            } => assert_eq!(health_interval, 15),
            other => panic!("expected serve, got {other:?}"),
        }
    }

    #[test]
    fn parse_clear_history_aliases() {
        assert!(matches!(
            Cli::parse_from(args(&["clear-autodl-history"]))
                .unwrap()
                .command,
            CommandKind::ClearAutodlHistory
        ));
        assert!(matches!(
            Cli::parse_from(args(&["clear-ssh-history"]))
                .unwrap()
                .command,
            CommandKind::ClearAutodlHistory
        ));
    }

    #[test]
    fn parse_help() {
        assert!(matches!(
            Cli::parse_from(args(&["--help"])).unwrap().command,
            CommandKind::Help
        ));
    }

    #[test]
    fn parse_rejects_unknown_subcommand_and_option() {
        assert!(Cli::parse_from(args(&["bogus"])).is_err());
        assert!(Cli::parse_from(args(&["serve", "--nope"])).is_err());
        assert!(Cli::parse_from(args(&["serve", "--port", "notnum"])).is_err());
    }
}
