use librustdesk::*;

#[cfg(not(target_os = "macos"))]
fn main() {}

#[cfg(target_os = "macos")]
fn main() {
    crate::common::load_custom_client();
    hbb_common::init_log(false, "service");
    crate::common::bootstrap_deskzap_host();
    crate::start_os_service();
}
