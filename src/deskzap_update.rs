// Deskzap remote self-update (Windows Host).
//
// The control plane flags a device with `metadata.pending_update` and returns
// `latest_version`, `update_url` and `update_sha256` in the runtime-heartbeat
// response. Only the SYSTEM service process acts on it: it downloads the Host
// installer, verifies the sha256, and hands over to a detached helper (a
// one-shot SYSTEM scheduled task) that stops the service, backs up the install
// folder and `deskzap-profile.json`, runs the installer silently, restores the
// profile and starts the service — rolling the backup back if the service does
// not come up. Success is reported implicitly by the new `build_version` on the
// next heartbeat; failure by `update_error`. The device ID and heartbeat token
// live in the service's config folder, outside the install folder.
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::Path;

/// What the heartbeat response asks this build to do.
#[derive(Debug, PartialEq)]
pub enum Decision {
    /// Nothing to do.
    None,
    /// Flagged, but the instruction can't be acted on safely (logged only).
    Skip(String),
    Apply {
        version: String,
        url: String,
        sha256: String,
    },
}

fn str_field<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

/// Decides from a runtime-heartbeat response. Never compares against the
/// RustDesk core version (`agent_version`, e.g. `1.4.6`): only the baked Deskzap
/// build version is meaningful, and versions are compared for equality, not
/// order — the server decides what "latest" is.
pub fn decide(response: &Value, installed_build: Option<&str>) -> Decision {
    let metadata = response.pointer("/device/metadata");
    let pending = metadata
        .and_then(|m| m.get("pending_update"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if !pending {
        return Decision::None;
    }
    // An unstamped (local/dev) build has no version to compare: never update it.
    let Some(installed) = installed_build else {
        return Decision::Skip("this build has no build_version".into());
    };
    let latest = metadata
        .and_then(|m| str_field(m, "latest_version"))
        .or_else(|| str_field(response, "latest_version"));
    let Some(latest) = latest else {
        return Decision::Skip("no latest_version".into());
    };
    if latest == installed {
        return Decision::None;
    }
    let Some(url) = str_field(response, "update_url") else {
        return Decision::Skip("no update_url".into());
    };
    if !url.starts_with("https://") {
        return Decision::Skip("update_url is not https".into());
    }
    let Some(sha256) = str_field(response, "update_sha256") else {
        return Decision::Skip("no update_sha256; refusing an unverifiable download".into());
    };
    let sha256 = sha256.to_ascii_lowercase();
    if sha256.len() != 64 || !sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Decision::Skip("update_sha256 is not a sha256 hex digest".into());
    }
    Decision::Apply {
        version: latest.to_owned(),
        url: url.to_owned(),
        sha256,
    }
}

/// Fail-safe check: a download whose hash doesn't match is deleted, so a
/// corrupt or tampered installer can never be run.
pub fn verify_download(path: &Path, expected_sha256: &str) -> Result<(), String> {
    let bytes = std::fs::read(path).map_err(|e| format!("cannot read download: {e}"))?;
    let actual = hex::encode(Sha256::digest(&bytes));
    if actual.eq_ignore_ascii_case(expected_sha256) {
        Ok(())
    } else {
        let _ = std::fs::remove_file(path);
        Err(format!(
            "sha256 mismatch (expected {expected_sha256}, got {actual})"
        ))
    }
}

#[cfg(windows)]
pub use platform::{on_heartbeat_response, set_update_owner, take_update_error, clear_update_error};

#[cfg(not(windows))]
pub fn on_heartbeat_response(_response: &str) {}
#[cfg(not(windows))]
pub fn set_update_owner() {}
#[cfg(not(windows))]
pub fn take_update_error() -> Option<String> {
    None
}
#[cfg(not(windows))]
pub fn clear_update_error() {}

#[cfg(windows)]
mod platform {
    use super::{decide, verify_download, Decision};
    use hbb_common::log;
    use std::{
        io::Write,
        path::PathBuf,
        process::Command,
        sync::atomic::{AtomicBool, Ordering},
        time::{Duration, SystemTime},
    };

    const TASK_NAME: &str = "DeskzapHostUpdate";
    const HELPER: &str = include_str!("deskzap_update_apply.ps1");
    /// Don't re-attempt the same version sooner than this, even if the server
    /// still says pending (e.g. the failure report was lost).
    const RETRY_AFTER: Duration = Duration::from_secs(60 * 60);

    static OWNER: AtomicBool = AtomicBool::new(false);
    static IN_FLIGHT: AtomicBool = AtomicBool::new(false);

    /// Only the SYSTEM service process may apply updates; the `--server` and
    /// UI processes also heartbeat but must never act on the flag.
    pub fn set_update_owner() {
        OWNER.store(true, Ordering::SeqCst);
    }

    fn update_dir() -> PathBuf {
        let base = std::env::var("ProgramData").unwrap_or_else(|_| "C:\\ProgramData".into());
        PathBuf::from(base).join("Deskzap Host").join("update")
    }

    fn result_path() -> PathBuf {
        update_dir().join("update-error.txt")
    }

    fn record_error(msg: &str) {
        log::error!("Deskzap self-update failed: {msg}");
        let _ = std::fs::create_dir_all(update_dir());
        let _ = std::fs::write(result_path(), msg);
    }

    /// A failure reason waiting to be reported on the next heartbeat (written
    /// either by this process or by the helper after a rollback).
    pub fn take_update_error() -> Option<String> {
        std::fs::read_to_string(result_path())
            .ok()
            .map(|s| s.trim().to_owned())
            .filter(|s| !s.is_empty())
    }

    /// Called once a heartbeat carrying `update_error` was accepted.
    pub fn clear_update_error() {
        let _ = std::fs::remove_file(result_path());
    }

    fn recently_attempted(version: &str) -> bool {
        let marker = update_dir().join("last-attempt.txt");
        let Ok(meta) = std::fs::metadata(&marker) else {
            return false;
        };
        let same = std::fs::read_to_string(&marker)
            .map(|s| s.trim() == version)
            .unwrap_or(false);
        let fresh = meta
            .modified()
            .ok()
            .and_then(|m| SystemTime::now().duration_since(m).ok())
            .map(|age| age < RETRY_AFTER)
            .unwrap_or(false);
        same && fresh
    }

    pub fn on_heartbeat_response(response: &str) {
        if !OWNER.load(Ordering::SeqCst) {
            return;
        }
        let Ok(json) = serde_json::from_str::<serde_json::Value>(response) else {
            return;
        };
        match decide(&json, crate::common::deskzap_build_version()) {
            Decision::None => {}
            Decision::Skip(reason) => log::info!("Deskzap self-update not applied: {reason}"),
            Decision::Apply { version, url, sha256 } => {
                if recently_attempted(&version) || IN_FLIGHT.swap(true, Ordering::SeqCst) {
                    return;
                }
                std::thread::spawn(move || {
                    if let Err(err) = apply(&version, &url, &sha256) {
                        record_error(&err);
                    }
                    IN_FLIGHT.store(false, Ordering::SeqCst);
                });
            }
        }
    }

    fn apply(version: &str, url: &str, sha256: &str) -> Result<(), String> {
        let dir = update_dir();
        std::fs::create_dir_all(&dir).map_err(|e| format!("cannot create {dir:?}: {e}"))?;
        let _ = std::fs::write(dir.join("last-attempt.txt"), version);
        log::info!("Deskzap self-update: downloading {version}");

        let installer = dir.join("deskzap-host-installer.exe");
        let client = crate::hbbs_http::create_http_client_with_url(url);
        let mut resp = client
            .get(url)
            .send()
            .map_err(|e| format!("download failed: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("download failed: HTTP {}", resp.status()));
        }
        let mut file =
            std::fs::File::create(&installer).map_err(|e| format!("cannot write installer: {e}"))?;
        resp.copy_to(&mut file)
            .map_err(|e| format!("download interrupted: {e}"))?;
        file.flush().map_err(|e| format!("cannot write installer: {e}"))?;
        drop(file);
        verify_download(&installer, sha256)?;

        let install_dir = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.to_path_buf()))
            .ok_or("cannot locate the install folder")?;
        let helper = dir.join("apply-update.ps1");
        let script = HELPER
            .replace("__INSTALL_DIR__", &install_dir.to_string_lossy())
            .replace("__INSTALLER__", &installer.to_string_lossy())
            .replace("__RESULT_FILE__", &result_path().to_string_lossy())
            .replace("__TASK_NAME__", TASK_NAME)
            .replace("__VERSION__", version);
        std::fs::write(&helper, script).map_err(|e| format!("cannot write helper: {e}"))?;

        // A SYSTEM scheduled task outlives this service, which the helper is
        // about to stop; a child process might not.
        let action = format!(
            "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"{}\"",
            helper.to_string_lossy()
        );
        run("schtasks", &["/Create", "/F", "/TN", TASK_NAME, "/RU", "SYSTEM", "/RL", "HIGHEST", "/SC", "ONCE", "/ST", "00:00", "/TR", &action])?;
        run("schtasks", &["/Run", "/TN", TASK_NAME])?;
        log::info!("Deskzap self-update: {version} verified, helper started");
        Ok(())
    }

    fn run(cmd: &str, args: &[&str]) -> Result<(), String> {
        let out = Command::new(cmd)
            .args(args)
            .output()
            .map_err(|e| format!("{cmd} failed to start: {e}"))?;
        if out.status.success() {
            Ok(())
        } else {
            Err(format!(
                "{cmd} {} failed: {}",
                args.first().unwrap_or(&""),
                String::from_utf8_lossy(&out.stderr).trim()
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const SHA: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    fn resp(pending: bool, latest: &str) -> Value {
        json!({
            "device": { "agent_version": "1.4.6", "metadata": { "pending_update": pending, "latest_version": latest } },
            "latest_version": latest,
            "update_url": "https://my.deskzap.co.uk/api/v1/installers/public-artifacts/windows/host/download",
            "update_sha256": SHA,
        })
    }

    #[test]
    fn core_version_never_makes_the_build_look_out_of_date() {
        // agent_version 1.4.6 vs a 0.1.0-preview build: only build_version counts.
        let r = resp(true, "0.1.0-preview.7.1");
        assert_eq!(decide(&r, Some("0.1.0-preview.7.1")), Decision::None);
        // And without a server flag nothing happens, whatever the versions.
        assert_eq!(decide(&resp(false, "0.1.0-preview.9.1"), Some("0.1.0-preview.7.1")), Decision::None);
    }

    #[test]
    fn flagged_and_different_applies_with_the_given_hash() {
        match decide(&resp(true, "0.1.0-preview.9.1"), Some("0.1.0-preview.7.1")) {
            Decision::Apply { version, sha256, .. } => {
                assert_eq!(version, "0.1.0-preview.9.1");
                assert_eq!(sha256, SHA);
            }
            other => panic!("expected Apply, got {other:?}"),
        }
    }

    #[test]
    fn unverifiable_or_unstamped_updates_are_refused() {
        let mut r = resp(true, "0.1.0-preview.9.1");
        assert!(matches!(decide(&r, None), Decision::Skip(_)));
        r["update_sha256"] = json!("not-a-hash");
        assert!(matches!(decide(&r, Some("0.1.0-preview.7.1")), Decision::Skip(_)));
        r.as_object_mut().unwrap().remove("update_sha256");
        assert!(matches!(decide(&r, Some("0.1.0-preview.7.1")), Decision::Skip(_)));
        let mut r = resp(true, "0.1.0-preview.9.1");
        r["update_url"] = json!("http://example.com/x.exe");
        assert!(matches!(decide(&r, Some("0.1.0-preview.7.1")), Decision::Skip(_)));
    }

    #[test]
    fn corrupt_download_is_rejected_and_deleted() {
        let path = std::env::temp_dir().join(format!("deskzap-update-test-{}.bin", std::process::id()));
        std::fs::write(&path, b"installer bytes").unwrap();
        let good = hex::encode(Sha256::digest(b"installer bytes"));
        assert!(verify_download(&path, &good.to_uppercase()).is_ok());
        assert!(path.exists());
        assert!(verify_download(&path, SHA).is_err());
        assert!(!path.exists(), "a mismatched download must be deleted");
    }
}
