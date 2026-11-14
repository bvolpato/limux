use gtk4::glib;
use std::sync::{Arc, Mutex};
use std::time::Duration;

type Tick = Box<dyn FnMut() + Send>;

struct Pending {
    idle: glib::Source,
    fallback: glib::Source,
    tick: Tick,
}

#[derive(Default)]
struct State {
    pending: Option<Pending>,
    running: bool,
    requested: bool,
}

/// Coalesce Ghostty mailbox notifications without polling an idle app.
#[derive(Default)]
pub(super) struct Wakeup {
    state: Arc<Mutex<State>>,
}

impl Wakeup {
    pub(super) fn queue(&self, context: &glib::MainContext, tick: impl FnMut() + Send + 'static) {
        let mut state = self.state.lock().unwrap();
        if state.running {
            state.requested = true;
        } else if state.pending.is_none() {
            attach_tick(context, &self.state, &mut state, Box::new(tick));
        }
    }
}

fn attach_tick(
    context: &glib::MainContext,
    shared: &Arc<Mutex<State>>,
    state: &mut State,
    tick: Tick,
) {
    let dispatch = || {
        let context = context.clone();
        let shared = shared.clone();
        move || {
            dispatch_tick(&context, &shared);
            glib::ControlFlow::Break
        }
    };
    let idle = glib::idle_source_new(
        Some("limux-ghostty-wakeup"),
        glib::Priority::DEFAULT_IDLE,
        dispatch(),
    );
    // Preserve the immediate idle path and the former timer's priority under
    // busy input. The fallback exists only while mailbox work is pending.
    let fallback = glib::timeout_source_new(
        Duration::from_millis(1),
        Some("limux-ghostty-wakeup-fallback"),
        glib::Priority::DEFAULT,
        dispatch(),
    );
    idle.attach(Some(context));
    fallback.attach(Some(context));
    // The state lock prevents either callback from running before both sources
    // are attached and their cancellation handles are available.
    state.pending = Some(Pending {
        idle,
        fallback,
        tick,
    });
}

fn dispatch_tick(context: &glib::MainContext, shared: &Arc<Mutex<State>>) {
    let mut pending = {
        let mut state = shared.lock().unwrap();
        let Some(pending) = state.pending.take() else {
            return;
        };
        state.running = true;
        pending
    };
    pending.idle.destroy();
    pending.fallback.destroy();
    (pending.tick)();

    let mut state = shared.lock().unwrap();
    state.running = false;
    if std::mem::take(&mut state.requested) {
        // Arm the next fallback after the drain. It must not already be due
        // when a long tick returns and prevent GTK's frame sources from running.
        attach_tick(context, shared, &mut state, pending.tick);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Instant;

    fn run_until(context: &glib::MainContext, ready: impl Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(1);
        while !ready() {
            assert!(
                Instant::now() < deadline,
                "main context stopped delivering work"
            );
            context.iteration(false);
            std::thread::yield_now();
        }
    }

    #[test]
    fn coalesces_wakeups_and_leaves_idle_context_without_a_timer() {
        let context = glib::MainContext::new();
        let wakeup = Wakeup::default();
        let ticks = Arc::new(AtomicUsize::new(0));
        for _ in 0..64 {
            let ticks = ticks.clone();
            wakeup.queue(&context, move || {
                ticks.fetch_add(1, Ordering::Relaxed);
            });
        }

        run_until(&context, || ticks.load(Ordering::Relaxed) > 0);
        assert_eq!(ticks.load(Ordering::Relaxed), 1);
        std::thread::sleep(Duration::from_millis(10));
        assert!(!context.pending(), "idle app retained a polling source");
        assert!(!context.iteration(false));
    }

    #[test]
    fn wakeup_from_another_thread_during_tick_gets_its_own_turn() {
        let context = glib::MainContext::new();
        let wakeup = Arc::new(Wakeup::default());
        let ticks = Arc::new(AtomicUsize::new(0));
        wakeup.queue(&context, {
            let context = context.clone();
            let wakeup = wakeup.clone();
            let ticks = ticks.clone();
            move || {
                if ticks.fetch_add(1, Ordering::Relaxed) == 0 {
                    let context = context.clone();
                    let wakeup = wakeup.clone();
                    let ticks = ticks.clone();
                    std::thread::spawn(move || {
                        wakeup.queue(&context, move || {
                            ticks.fetch_add(1, Ordering::Relaxed);
                        });
                    })
                    .join()
                    .unwrap();
                }
            }
        });

        run_until(&context, || ticks.load(Ordering::Relaxed) == 2);
        assert!(!context.pending());
    }

    #[test]
    fn tick_survives_busy_input_and_yields_to_frame_sources() {
        let context = glib::MainContext::new();
        let wakeup = Arc::new(Wakeup::default());
        let ticks = Arc::new(AtomicUsize::new(0));
        let input = glib::idle_source_new(None, glib::Priority::DEFAULT, || {
            glib::ControlFlow::Continue
        });
        input.attach(Some(&context));
        wakeup.queue(&context, {
            let ticks = ticks.clone();
            move || {
                ticks.fetch_add(1, Ordering::Relaxed);
            }
        });
        run_until(&context, || ticks.load(Ordering::Relaxed) == 1);
        input.destroy();
        assert!(!context.pending(), "fallback left a stale idle callback");

        let frames = Arc::new(AtomicUsize::new(0));
        // GTK frame-clock paint sources run at GDK_PRIORITY_REDRAW (120).
        let frame = glib::idle_source_new(None, glib::Priority::from(120), {
            let frames = frames.clone();
            move || {
                frames.fetch_add(1, Ordering::Relaxed);
                glib::ControlFlow::Continue
            }
        });
        frame.attach(Some(&context));
        wakeup.queue(&context, {
            let context = context.clone();
            let wakeup = wakeup.clone();
            let ticks = ticks.clone();
            let frames = frames.clone();
            move || {
                let previous = ticks.fetch_add(1, Ordering::Relaxed);
                if previous == 1 {
                    frames.store(0, Ordering::Relaxed);
                }
                if previous < 9 {
                    wakeup.queue(&context, || {});
                }
                // A refill arrives before a tick exceeding the timer interval
                // completes, as it can under sustained terminal output.
                std::thread::sleep(Duration::from_millis(2));
            }
        });
        run_until(&context, || ticks.load(Ordering::Relaxed) == 10);
        frame.destroy();
        assert!(
            frames.load(Ordering::Relaxed) > 0,
            "ticks starved GTK frames"
        );
    }
}
