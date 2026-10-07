use super::*;

fn pump_until(mut done: impl FnMut() -> bool) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while !done() {
        assert!(
            std::time::Instant::now() < deadline,
            "session save timed out"
        );
        while glib::MainContext::default().pending() {
            glib::MainContext::default().iteration(false);
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
}

#[test]
#[ignore = "requires GTK; exercised by xvfb-smoke-test.sh"]
fn close_during_pending_save_persists_the_latest_snapshot() {
    let temp = tempfile::tempdir().unwrap();
    for key in ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME"] {
        let path = temp.path().join(key);
        std::fs::create_dir_all(&path).unwrap();
        std::env::set_var(key, path);
    }
    crate::prepare_ghostty_runtime();
    adw::init().unwrap();
    crate::terminal::init_ghostty();
    let app = adw::Application::builder()
        .application_id("dev.limux.SessionSaveTest")
        .build();
    app.register(None::<&gio::Cancellable>).unwrap();
    build_window(&app);
    let state = CONTROL_STATE.with(|slot| slot.borrow().as_ref().unwrap().clone());
    let window = state.borrow().window.clone();
    pump_until(|| matches!(state.borrow().session_store, Ok(Some(_))) && window.is_mapped());

    let directory = layout_state::persistence_dir();
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(directory.join("session.lock"))
        .unwrap();
    lock.lock().unwrap();
    state.borrow_mut().workspaces[0].name = "first queued snapshot".into();
    request_session_save(&state);
    pump_until(|| matches!(state.borrow().session_store, Ok(None)));
    state.borrow_mut().workspaces[0].name = "edit while saving".into();
    window.close();
    assert!(state.borrow().session_close_pending.is_some());
    assert!(window.is_visible(), "close must wait for the final save");

    let dispatched = Rc::new(Cell::new(false));
    let tick = dispatched.clone();
    glib::timeout_add_local_once(std::time::Duration::from_millis(30), move || {
        tick.set(true);
    });
    pump_until(|| dispatched.get());
    assert!(window.is_visible());
    state.borrow_mut().workspaces[0].name = "latest edit while closing".into();
    drop(lock);
    pump_until(|| !window.is_visible());
    let saved: AppSessionState = serde_json::from_slice(
        &std::fs::read(layout_state::canonical_session_path_in(&directory)).unwrap(),
    )
    .unwrap();
    assert_eq!(saved.workspaces[0].name, "latest edit while closing");
    assert!(state.borrow().persistence_suspended);
    assert!(state.borrow().session_save_timer.is_none());
}
