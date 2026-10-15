mod controls;
mod layout;
mod transport;

use block2::RcBlock;
use controls::{Lifecycle, NativeNode, Page, pointer, rect};
use live_sidestep_protocol::{Command, QUEUE_CAPACITY, State};
use objc2::rc::{Retained, autoreleasepool};
use objc2::runtime::ProtocolObject;
use objc2::{DefinedClass, MainThreadMarker, MainThreadOnly, Message, define_class, msg_send};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSApplicationDelegate, NSAutoresizingMaskOptions,
    NSBackingStoreType, NSScrollView, NSView, NSWindow, NSWindowDelegate, NSWindowStyleMask,
};
use objc2_foundation::{
    NSNotification, NSObject, NSObjectProtocol, NSRunLoop, NSRunLoopCommonModes, NSSize, NSString,
    NSTimer,
};
use serde::ser::{Serialize, SerializeMap, Serializer};
use serde_json::json;
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::ptr::NonNull;
use std::rc::Rc;
use std::sync::mpsc;
use std::time::{Duration, Instant};
use transport::{Incoming, Output};

// Links the real Sidestep Objective-C runtime and AppKit implementation on
// Linux, and native AppKit on macOS; this is not a substitute renderer.
use sidestep as _;

struct Host {
    state: State,
    nodes: BTreeMap<String, NativeNode>,
    window: Retained<NSWindow>,
    scroll: Retained<NSScrollView>,
    document: Retained<Page>,
    lifecycle: Rc<Lifecycle>,
    incoming: mpsc::Receiver<Incoming>,
    frames: u64,
    viewport: NSSize,
    layout_dirty: bool,
    mtm: MainThreadMarker,
}

struct Inspection<'a> {
    host: &'a Host,
    request: u64,
}

impl Serialize for Inspection<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(Some(8))?;
        map.serialize_entry("type", "inspection")?;
        map.serialize_entry("request", &self.request)?;
        map.serialize_entry("generation", &self.host.state.generation)?;
        map.serialize_entry("revision", &self.host.state.revision)?;
        map.serialize_entry("host_pid", &std::process::id())?;
        map.serialize_entry("frames", &self.host.frames)?;
        map.serialize_entry("nodes", &InspectedNodes(self.host))?;
        map.serialize_entry(
            "root",
            &self.host.state.tree.as_ref().map(|tree| &tree.root),
        )?;
        map.end()
    }
}

struct InspectedNodes<'a>(&'a Host);

impl Serialize for InspectedNodes<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(Some(self.0.nodes.len()))?;
        // Serialize one native node at a time. The bounded output writer
        // stops before cloning diagnostics for an arbitrarily large tree.
        for (id, node) in &self.0.nodes {
            map.serialize_entry(id, &node.inspect(&self.0.scroll))?;
        }
        map.end()
    }
}

impl Host {
    fn new(
        delegate: &Delegate,
        incoming: mpsc::Receiver<Incoming>,
        lifecycle: Rc<Lifecycle>,
    ) -> Self {
        let mtm = delegate.mtm();
        let size = NSSize::new(800.0, 600.0);
        // SAFETY: all native objects are created and subsequently owned only
        // on AppKit's main thread.
        let window = unsafe {
            NSWindow::initWithContentRect_styleMask_backing_defer(
                NSWindow::alloc(mtm),
                rect(120.0, 120.0, size.width, size.height),
                NSWindowStyleMask::Titled
                    | NSWindowStyleMask::Closable
                    | NSWindowStyleMask::Miniaturizable
                    | NSWindowStyleMask::Resizable,
                NSBackingStoreType::Buffered,
                false,
            )
        };
        // SAFETY: Rust retains the window; closing must not release that retain.
        unsafe { window.setReleasedWhenClosed(false) };
        window.setTitle(&NSString::from_str("LiveSidestep"));
        window.setContentMinSize(NSSize::new(200.0, 200.0));
        window.setDelegate(Some(ProtocolObject::from_ref(delegate)));
        let scroll = NSScrollView::initWithFrame(
            NSScrollView::alloc(mtm),
            rect(0.0, 0.0, size.width, size.height),
        );
        scroll.setAutoresizingMask(
            NSAutoresizingMaskOptions::ViewWidthSizable
                | NSAutoresizingMaskOptions::ViewHeightSizable,
        );
        scroll.setHasVerticalScroller(true);
        scroll.setHasHorizontalScroller(false);
        scroll.setAutohidesScrollers(true);
        let document = Page::new(mtm, rect(0.0, 0.0, size.width, size.height));
        scroll.setDocumentView(Some(&document));
        window.setContentView(Some(&scroll));
        Self {
            state: State::default(),
            nodes: BTreeMap::new(),
            window,
            scroll,
            document,
            lifecycle,
            incoming,
            frames: 0,
            viewport: NSSize::ZERO,
            layout_dirty: true,
            mtm,
        }
    }

    fn tick(&mut self) {
        if self.lifecycle.closed.get() {
            return;
        }
        self.frames = self.frames.saturating_add(1);
        self.finish_ended_inputs();
        let active = self.lifecycle.active_input.borrow().clone();
        if let Some(node) = active.as_deref().and_then(|id| self.nodes.get(id)) {
            node.poll_composition();
        }
        // Both queue length and wall time are bounded. A continuous stream of
        // snapshots cannot starve native mouse/key/IME dispatch.
        let deadline = Instant::now() + Duration::from_millis(4);
        for _ in 0..QUEUE_CAPACITY {
            if self.lifecycle.closed.get() || Instant::now() >= deadline {
                break;
            }
            match self.incoming.try_recv() {
                Ok(incoming) => {
                    // Delegate notifications normally already emitted these
                    // edits. Observe again before changing the declaration so
                    // an old application echo cannot race an unobserved edit.
                    self.observe_edits();
                    self.process(incoming);
                }
                Err(mpsc::TryRecvError::Empty) => break,
                Err(mpsc::TryRecvError::Disconnected) => {
                    self.close("stdin_eof");
                    break;
                }
            }
        }
        if !self.lifecycle.closed.get() {
            self.layout();
        }
    }

    fn observe_edits(&self) {
        self.finish_ended_inputs();
        let active = self.lifecycle.active_input.borrow().clone();
        if let Some(node) = active.as_deref().and_then(|id| self.nodes.get(id)) {
            node.observe_input();
        }
    }

    fn finish_ended_inputs(&self) {
        let ended = std::mem::take(&mut *self.lifecycle.ended_inputs.borrow_mut());
        for id in ended {
            if let Some(node) = self.nodes.get(&*id) {
                node.observe_input();
            }
        }
    }

    fn process(&mut self, incoming: Incoming) {
        match incoming {
            Incoming::Eof => self.close("stdin_eof"),
            Incoming::Invalid(reason) => self.resync(reason),
            Incoming::Command(Command::Shutdown) => self.close("shutdown"),
            Incoming::Command(Command::Configure {
                title,
                width,
                height,
            }) => {
                if self.window.title().to_string() != title {
                    self.window.setTitle(&NSString::from_str(&title));
                }
                let size = NSSize::new(f64::from(width), f64::from(height));
                self.window.setContentSize(size);
                self.layout_dirty = true;
            }
            Incoming::Command(Command::Inspect { request }) => {
                self.layout();
                self.lifecycle.output.inspection(
                    request,
                    &Inspection {
                        host: self,
                        request,
                    },
                );
            }
            Incoming::Command(command) => {
                let generation = self.state.generation;
                let first_tree = self.state.tree.is_none();
                match self.state.apply(command) {
                    Ok(true) => {
                        self.reconcile();
                        self.layout();
                        // Do not map an empty, default-sized window while its
                        // initial configuration and controls are still pending.
                        if first_tree {
                            self.window.makeKeyAndOrderFront(None);
                        }
                        self.lifecycle.output.send(json!({
                            "type":"applied", "generation":self.state.generation, "revision":self.state.revision
                        }));
                        if generation != self.state.generation {
                            for node in self.nodes.values() {
                                node.replay();
                            }
                        }
                    }
                    Ok(false) => {}
                    Err(reason) => self.resync(reason),
                }
            }
        }
    }

    fn resync(&self, reason: String) {
        self.lifecycle.output.send(json!({
            "type":"resync", "generation":self.state.generation,
            "revision":self.state.revision, "reason":reason
        }));
    }

    fn reconcile(&mut self) {
        let tree = self.state.tree.as_ref().expect("applied tree");
        // Removing an obsolete parent before moving its retained children can
        // end their field-editor sessions. First retire only removed/replaced
        // leaves; detach obsolete containers only after all survivors moved.
        for (id, native) in &self.nodes {
            if !tree
                .nodes
                .get(id)
                .is_some_and(|node| native.compatible(node))
                && !matches!(native.node.kind.as_str(), "column" | "row" | "list")
            {
                native.retire();
            }
        }
        let mut retired = Vec::new();
        self.nodes.retain(|id, native| {
            let keep = tree
                .nodes
                .get(id)
                .is_some_and(|node| native.compatible(node));
            if !keep && matches!(native.node.kind.as_str(), "column" | "row" | "list") {
                // The parent's view is retained separately until surviving
                // descendants have joined their desired parent.
                retired.push(
                    unsafe { Retained::retain(native.view() as *const NSView as *mut NSView) }
                        .expect("a retained native view"),
                );
            }
            keep
        });
        for (id, node) in &tree.nodes {
            if !self.nodes.contains_key(id) {
                self.nodes.insert(
                    id.clone(),
                    NativeNode::new(
                        node,
                        self.state.generation,
                        self.state.revision,
                        self.lifecycle.clone(),
                        self.mtm,
                    ),
                );
            }
        }
        // Publish all event identities before any setters can call delegates.
        for (id, node) in &tree.nodes {
            self.nodes[id].context(node, self.state.generation, self.state.revision);
        }
        for (id, node) in &tree.nodes {
            self.nodes.get_mut(id).expect("created node").update(node);
        }
        // An old ancestor may become a desired descendant. Detach the new
        // root first, then move parents before their children so no transient
        // native hierarchy can contain a view beneath its own descendant.
        Self::attach(self.nodes[&tree.root].view(), &self.document);
        let mut pending = vec![tree.root.as_str()];
        while let Some(id) = pending.pop() {
            let parent = self.nodes[id].view();
            for child in tree.nodes[id].children.iter().rev() {
                Self::attach(self.nodes[child].view(), parent);
                pending.push(child);
            }
        }
        for view in retired {
            view.removeFromSuperview();
        }
        layout::update_intrinsics(tree, &self.nodes);
        self.layout_dirty = true;
        // AppKit derives keyboard navigation from the actual new geometry.
        // This does not touch the current field editor or first responder.
        self.window.recalculateKeyViewLoop();
    }

    fn attach(child: &NSView, parent: &NSView) {
        // A keyed reorder only changes frames. Do not remove/add a survivor
        // merely to change sibling order, which would throw away native focus.
        let same_parent = unsafe { child.superview() }
            .is_some_and(|existing| pointer(&*existing) == pointer(parent));
        if !same_parent {
            parent.addSubview(child);
        }
    }

    fn layout(&mut self) {
        let viewport = self.scroll.contentSize();
        if self.layout_dirty || viewport != self.viewport {
            if let Some(tree) = &self.state.tree {
                layout::place(tree, &self.nodes, &self.document, viewport);
            } else if self.document.frame().size != viewport {
                self.document.setFrameSize(viewport);
            }
            self.viewport = viewport;
            self.layout_dirty = false;
        }
    }

    fn close(&self, reason: &str) {
        self.lifecycle.close(reason);
        self.window.close();
    }
}

struct DelegateIvars {
    host: RefCell<Option<Host>>,
    incoming: RefCell<Option<mpsc::Receiver<Incoming>>>,
    lifecycle: Rc<Lifecycle>,
}

define_class!(
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "LiveSidestepApplicationDelegate"]
    #[ivars = DelegateIvars]
    struct Delegate;

    unsafe impl NSObjectProtocol for Delegate {}

    unsafe impl NSWindowDelegate for Delegate {
        #[unsafe(method(windowWillClose:))]
        fn window_will_close(&self, _notification: &NSNotification) {
            // This may be called synchronously while Host owns its borrow.
            // Lifecycle is independent and never reborrows Host.
            self.ivars().lifecycle.close("window_closed");
        }
    }

    unsafe impl NSApplicationDelegate for Delegate {
        #[unsafe(method(applicationDidFinishLaunching:))]
        fn did_finish_launching(&self, _notification: &NSNotification) {
            let incoming = self
                .ivars()
                .incoming
                .borrow_mut()
                .take()
                .expect("one launch");
            let host = Host::new(self, incoming, self.ivars().lifecycle.clone());
            self.ivars().host.replace(Some(host));
            self.ivars().lifecycle.output.send(json!({
                "type":"ready", "protocol":1, "host_pid":std::process::id()
            }));
            let delegate = self.retain();
            let block = RcBlock::new(move |_: NonNull<NSTimer>| {
                autoreleasepool(|_| {
                    // Native tracking may enter a nested run loop. Skipping a
                    // nested tick is safe; a global RefCell borrow panic is not.
                    if let Ok(mut host) = delegate.ivars().host.try_borrow_mut()
                        && let Some(host) = host.as_mut()
                    {
                        host.tick();
                    }
                });
            });
            // SAFETY: the run loop retains this repeating timer and its block;
            // common modes keep native controls live during tracking/resizing.
            unsafe {
                let timer = NSTimer::timerWithTimeInterval_repeats_block(1.0 / 120.0, true, &block);
                NSRunLoop::currentRunLoop().addTimer_forMode(&timer, NSRunLoopCommonModes);
            }
        }

        #[unsafe(method(applicationShouldTerminateAfterLastWindowClosed:))]
        fn should_terminate_after_last_window(&self, _sender: &NSApplication) -> bool {
            // The output thread flushes `closed` then exits; AppKit must not
            // terminate the process before that bounded response is written.
            false
        }
    }
);

impl Delegate {
    fn new(
        mtm: MainThreadMarker,
        incoming: mpsc::Receiver<Incoming>,
        lifecycle: Rc<Lifecycle>,
    ) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(DelegateIvars {
            host: RefCell::new(None),
            incoming: RefCell::new(Some(incoming)),
            lifecycle,
        });
        // SAFETY: NSObject's initializer with initialized Rust ivars.
        unsafe { msg_send![super(this), init] }
    }
}

fn main() {
    let mtm = MainThreadMarker::new().expect("LiveSidestep host must run on its main thread");
    let output = Output::start();
    let incoming = transport::start_input();
    let lifecycle = Rc::new(Lifecycle {
        output,
        closed: Cell::new(false),
        active_input: RefCell::new(None),
        ended_inputs: RefCell::new(Default::default()),
    });
    let app = NSApplication::sharedApplication(mtm);
    app.setActivationPolicy(NSApplicationActivationPolicy::Regular);
    let delegate = Delegate::new(mtm, incoming, lifecycle.clone());
    app.setDelegate(Some(ProtocolObject::from_ref(&*delegate)));
    app.run();
    lifecycle.close("application_stopped");
    // app.run normally stays active until the writer's exit. If AppKit stops
    // independently, keep the process alive without waiting for I/O on main.
    loop {
        std::thread::park();
    }
}
