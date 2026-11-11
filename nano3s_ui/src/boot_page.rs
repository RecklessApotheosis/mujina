//! Chooses the page the display shows after a boot.
//!
//! The page name lives in a file on flash, so without this the display
//! comes up on whichever page was showing before the reboot. On the first
//! start after a boot we set it to [`BOOT_PAGE`].
//!
//! "First start after a boot" is decided by a marker file in /tmp, which
//! is empty after every boot. The supervisor loop restarts nano3s_ui when
//! it exits; the marker keeps such a restart from pulling the display back
//! to the boot page in the middle of the day.
//!
//! Not handled: on a unit that is not provisioned yet, ble_setup writes its
//! own "wifi-setup" page at boot and the two can race.

use std::fs::{self, OpenOptions};
use std::path::Path;

pub const BOOT_PAGE: &str = "reckless";
pub const MARKER: &str = "/tmp/nano3s_ui.started";
pub const PAGE_FILE: &str = "/mntapp/release/linux/app/fb_page";

/// Sets the page to [`BOOT_PAGE`] if `marker` did not exist, and creates
/// `marker`. Returns whether the page was set. If the marker cannot be
/// created the page is left alone: a wrong page at boot is better than
/// one that resets on every restart.
pub fn apply(marker: &Path, page_file: &Path) -> bool {
    // create_new is atomic: exactly one start per boot sees Ok.
    match OpenOptions::new().write(true).create_new(true).open(marker) {
        Ok(_) => fs::write(page_file, format!("{BOOT_PAGE}\n")).is_ok(),
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn scratch(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("nano3s_ui-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn first_start_after_boot_shows_the_boot_page() {
        let d = scratch("first");
        let (marker, page) = (d.join("started"), d.join("fb_page"));
        fs::write(&page, "nano3s-diag\n").unwrap();
        assert!(apply(&marker, &page));
        assert_eq!(fs::read_to_string(&page).unwrap(), "reckless\n");
        assert!(marker.exists());
    }

    #[test]
    fn a_restart_leaves_the_page_alone() {
        let d = scratch("restart");
        let (marker, page) = (d.join("started"), d.join("fb_page"));
        apply(&marker, &page);
        fs::write(&page, "nano3s\n").unwrap();
        assert!(!apply(&marker, &page));
        assert_eq!(fs::read_to_string(&page).unwrap(), "nano3s\n");
    }

    #[test]
    fn no_marker_means_no_page_change() {
        let d = scratch("nomarker");
        let (marker, page) = (d.join("missing-dir").join("started"), d.join("fb_page"));
        fs::write(&page, "ip\n").unwrap();
        assert!(!apply(&marker, &page));
        assert_eq!(fs::read_to_string(&page).unwrap(), "ip\n");
    }
}
