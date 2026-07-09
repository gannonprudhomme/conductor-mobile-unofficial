use std::{env, fs, os::unix::fs::PermissionsExt, path::{Path, PathBuf}};
use serde::Serialize;

const BRIDGE_MARKER: &str = "FAKE_CONDUCTOR_BRIDGE_MARKER;v0.1";

struct ConductorPaths {
    // The "actual" (our wrapper, in the ideal state) `conductor-runtime` path
    application_support_runtime_path: PathBuf,
    // the genuine-from-conductor `conductor-runtime` "backup" of sorts.
    // ofc not really a backup since our wrapper runs this
    application_support_runtime_real_path: PathBuf,

    // The `conductor-runtime` in this repo / bundle that we're going to install which runs our `runtime-proxy.mjs` bridge proxy
    source_fake_runtime_path: PathBuf,
    // The actual `runtime-proxy.mjs` which acts as our server / bridge
    source_runtime_proxy_js_path: PathBuf,
    // The location in Application Support for where our runtime-proxy.mjs is
    dest_runtime_proxy_js_path: PathBuf,

    // The /Applications/ path that we put our "fake" `conductor-runtime` so it'll get copied into Application Support/ whenever Conductor launches
    application_bundle_runtime_path: PathBuf,
}

impl ConductorPaths {
    fn new() -> Result<Self, String> {
        let home =
            env::var("HOME").map_err(|error| format!("Could not find HOME directory: {error}"))?;

        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .map(Path::to_path_buf)
            .ok_or("Could not resolve repository root")?;

        let source_bridge_dir = repo_root.join("sidecar-proxy");

        let application_support_dir = PathBuf::from(home)
            .join("Library")
            .join("Application Support")
            .join("com.conductor.app")
            .join("bin")
            .join(".internal");

        let applications_dir = PathBuf::from("/Applications")
            .join("Conductor.app")
            .join("Contents")
            .join("Resources")
            .join("bin")
            .join(".internal");

        Ok(ConductorPaths {
            application_support_runtime_path: application_support_dir.join("conductor-runtime"),
            application_support_runtime_real_path: application_support_dir.join("conductor-runtime.real"),
            source_fake_runtime_path: source_bridge_dir.join("conductor-runtime"),
            source_runtime_proxy_js_path: source_bridge_dir.join("dist").join("runtime-proxy.mjs"),
            dest_runtime_proxy_js_path: application_support_dir.join("runtime-proxy.mjs"),
            application_bundle_runtime_path: applications_dir.join("conductor-runtime"),
        })
    }
}

#[tauri::command]
pub fn install_bridge() -> Result<(), String> {
    // Move conductor-runtime -> conductor-runtime.real
    // copy in the .mjs?
    // swap in the shell script that runs the .mjs?

    let conductor_paths: ConductorPaths = ConductorPaths::new()?;

    if !conductor_paths.application_bundle_runtime_path.exists() { // if it doesn't exist, we got a problem
        return Err("There is no conductor-runtime file!".to_string());
    }

    // If the `conductor-runtime` IS our bridge then we don't want to copt it
    // thus if it's the original one move it from conductor-runtime -> conductor-runtime.real
    let is_conductor_runtime_our_bridge_proxy = is_file_our_bridge_runtime(&conductor_paths.application_bundle_runtime_path)?;
    if !is_conductor_runtime_our_bridge_proxy {
        // Move it from conductor-runtime -> conductor-runtime.real
        fs::copy(&conductor_paths.application_bundle_runtime_path, &conductor_paths.application_support_runtime_real_path)
            .map_err(|error| format!("Failed to move conductor-runtime -> conductor-runtime.real with error: {error}"))?;
    }

    // Copy in the Javascript file into the conductor internal directory (for the script to call it)
    fs::copy(&conductor_paths.source_runtime_proxy_js_path, &conductor_paths.dest_runtime_proxy_js_path)
        .map_err(|error| format!("Failed to copy runtime-proxy.mjs with error: {error}"))?;

    // Now move our fake conductor-runtime in the spot of the real one
    fs::copy(&conductor_paths.source_fake_runtime_path, &conductor_paths.application_bundle_runtime_path)
        .map_err(|error| format!("Failed to move fake runtime -> real one with error: {error}"))?;

    chmod_executable(&conductor_paths.application_bundle_runtime_path)?;

    Ok(())
}

#[tauri::command]
pub fn uninstall_bridge() -> Result<(), String> {
    // Remove the existing one and put conductor-runtime.real -> conductor-runtime
    let conductor_paths = ConductorPaths::new()?;

    fs::copy(&conductor_paths.application_support_runtime_real_path, &conductor_paths.application_bundle_runtime_path)
        .map_err(|err| format!("Failed to move conductor-runtime.real -> conductor.real with error: {err}"))?;

    Ok(())
}

// Returns whether the given file - conductor-runtime - contains the marker which we use
// to indicate that it's our proxied runtime
fn is_file_our_bridge_runtime(path: &Path) -> Result<bool, String> {
    match fs::read_to_string(path) {
        // If contains the BRIDGE_MARKER string, then we know it's our bridge proxy
        Ok(contents) => Ok(contents.contains(BRIDGE_MARKER)),
        // This is what happens whenever it's not installed in `conductor-runtime`, since it's a binary not UTF-8
        Err(error) if error.kind() == std::io::ErrorKind::InvalidData => Ok(false),
        Err(error) => Err(format!("Could not read {}: {error}", path.display())),
    }
}

fn chmod_executable(path: &Path) -> Result<(), String> {
    let mut permissions = fs::metadata(path)
        .map_err(|error| format!("Could not inspect {}: {error}", path.display()))?
        .permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions)
        .map_err(|error| format!("Could not chmod {}: {error}", path.display()))
}

#[derive(Serialize)]
pub struct BridgeStatus {
    is_bridge_installed_in_applications: bool,
    is_bridge_installed_in_application_support: bool,
    // Aka can we ping it / is it running
    is_bridge_reachable: bool,
}

#[tauri::command]
pub async fn get_bridge_status(client: tauri::State<'_, reqwest::Client>) -> Result<BridgeStatus, String> {
    let conductor_paths = ConductorPaths::new()?; 

    let is_bridge_installed_in_applications = is_file_our_bridge_runtime(&conductor_paths.application_bundle_runtime_path)?;
    let is_bridge_installed_in_application_support = is_file_our_bridge_runtime(&conductor_paths.application_support_runtime_path)?;

    const BRIDGE_BASE_URL: &str = "http://127.0.0.1:49321";

    // If it's not installed then don't fetch
    if !is_bridge_installed_in_application_support {
        return Ok(
            BridgeStatus {
                is_bridge_installed_in_applications,
                is_bridge_installed_in_application_support: false,
                is_bridge_reachable: false
            }
        )
    }

    let is_bridge_reachable: bool = client
        .get(format!("{BRIDGE_BASE_URL}/status"))
        .send()
        .await
        .map(|response| response.status().is_success())
        .unwrap_or(false);

    // Try to ping it

    return Ok(
        BridgeStatus {
            is_bridge_installed_in_applications,
            is_bridge_installed_in_application_support,
            is_bridge_reachable
        }
    )
}
