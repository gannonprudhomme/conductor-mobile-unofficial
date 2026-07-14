use std::{env, path::PathBuf, process::ExitCode, time::Duration};

mod installer;

enum Command {
    Install { resources: PathBuf },
    Uninstall,
    Status,
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    match parse_arguments(env::args().skip(1))? {
        Command::Install { resources } => installer::install_bridge_from(resources),
        Command::Uninstall => installer::uninstall_bridge(),
        Command::Status => {
            let client = reqwest::blocking::Client::builder()
                .timeout(Duration::from_secs(5))
                .build()
                .map_err(|error| format!("Could not create bridge HTTP client: {error}"))?;
            let status = installer::get_bridge_status_with_client(&client)?;
            println!(
                "{}",
                serde_json::to_string(&status)
                    .map_err(|error| format!("Could not encode bridge status: {error}"))?
            );
            Ok(())
        }
    }
}

fn parse_arguments(arguments: impl IntoIterator<Item = String>) -> Result<Command, String> {
    let mut arguments = arguments.into_iter();
    let command = match arguments.next().as_deref() {
        Some("install") => {
            if arguments.next().as_deref() != Some("--resources") {
                return Err(usage());
            }
            let resources = arguments.next().map(PathBuf::from).ok_or_else(usage)?;
            Command::Install { resources }
        }
        Some("uninstall") => Command::Uninstall,
        Some("status") => Command::Status,
        _ => return Err(usage()),
    };

    if arguments.next().is_some() {
        return Err(usage());
    }
    Ok(command)
}

fn usage() -> String {
    "Usage: conductor-bridge-installer install --resources <sidecar-proxy-dir> | uninstall | status"
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::{parse_arguments, Command};

    #[test]
    fn parses_install_resources() {
        let command = parse_arguments([
            "install".to_string(),
            "--resources".to_string(),
            "/tmp/sidecar-proxy".to_string(),
        ])
        .unwrap();

        let Command::Install { resources } = command else {
            panic!("expected install command");
        };
        assert_eq!(resources.to_str(), Some("/tmp/sidecar-proxy"));
    }
}
