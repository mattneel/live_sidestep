use crate::transport::Output;
use live_sidestep_host::text::{TextState, selection_after_replacement};
use live_sidestep_protocol::{MAX_TEXT_BYTES, Node};
use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2::{
    ClassType, DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send, sel,
};
use objc2_app_kit::{
    NSButton, NSControl, NSControlTextEditingDelegate, NSEvent, NSLineBreakMode, NSResponder,
    NSText, NSTextField, NSTextFieldDelegate, NSView,
};
use objc2_foundation::{
    NSNotification, NSObject, NSObjectProtocol, NSPoint, NSRange, NSRect, NSSize, NSString,
};
use serde_json::{Map, Value, json};
use std::cell::{Cell, RefCell};
use std::collections::BTreeSet;
use std::rc::Rc;

pub struct Lifecycle {
    pub output: Output,
    pub closed: Cell<bool>,
    pub active_input: RefCell<Option<Rc<str>>>,
    pub ended_inputs: RefCell<BTreeSet<Rc<str>>>,
}

impl Lifecycle {
    pub fn close(&self, reason: &str) {
        if !self.closed.replace(true) {
            self.output.close(reason);
        }
    }
}

pub fn rect(x: f64, y: f64, width: f64, height: f64) -> NSRect {
    NSRect::new(NSPoint::new(x, y), NSSize::new(width, height))
}

pub fn string<'a>(node: &'a Node, key: &str) -> &'a str {
    node.props.get(key).and_then(Value::as_str).unwrap_or("")
}

pub fn incarnation(node: &Node) -> u64 {
    node.props
        .get("incarnation")
        .and_then(Value::as_u64)
        .unwrap_or(0)
}

pub fn edit_revision(node: &Node) -> u64 {
    node.props
        .get("edit_revision")
        .and_then(Value::as_u64)
        .unwrap_or(0)
}

pub fn pointer<T>(object: &T) -> usize {
    object as *const T as usize
}

define_class!(
    #[unsafe(super(NSView, NSResponder, NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "LiveSidestepPage"]
    pub struct Page;

    impl Page {
        #[unsafe(method(isFlipped))]
        fn is_flipped(&self) -> bool {
            true
        }
    }
);

impl Page {
    pub fn new(mtm: MainThreadMarker, frame: NSRect) -> Retained<Self> {
        // SAFETY: an NSView subclass initialized on AppKit's main thread.
        unsafe { msg_send![Self::alloc(mtm), initWithFrame: frame] }
    }
}

define_class!(
    #[unsafe(super(NSButton, NSControl, NSView, NSResponder, NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "LiveSidestepButton"]
    struct NativeButton;

    impl NativeButton {
        #[unsafe(method(acceptsFirstMouse:))]
        fn accepts_first_mouse(&self, _event: Option<&NSEvent>) -> bool {
            // A push button must act on its first click, including activation.
            true
        }
    }
);

define_class!(
    #[unsafe(super(NSTextField, NSControl, NSView, NSResponder, NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "LiveSidestepInput"]
    struct NativeInput;

    impl NativeInput {
        #[unsafe(method(acceptsFirstMouse:))]
        fn accepts_first_mouse(&self, _event: Option<&NSEvent>) -> bool {
            true
        }
    }
);

struct EventDeclaration {
    id: String,
    kind: &'static str,
    incarnation: u64,
    generation: u64,
    revision: u64,
    name: Option<String>,
    params: Map<String, Value>,
    text: Option<TextState>,
}

impl EventDeclaration {
    fn event(&self) -> Option<Value> {
        let name = self.name.as_ref()?;
        let mut params = self.params.clone();
        if let Some(text) = &self.text {
            params.insert("value".into(), json!(text.value));
            params.insert("edit_revision".into(), json!(text.revision));
        }
        Some(json!({
            "type":"event", "generation":self.generation, "revision":self.revision,
            "node":self.id, "incarnation":self.incarnation, "kind":self.kind,
            "name":name, "params":params
        }))
    }

    fn update_properties(&mut self, node: &Node) {
        let property = if self.text.is_some() {
            "phx-change"
        } else {
            "phx-click"
        };
        self.name = node
            .props
            .get(property)
            .and_then(Value::as_str)
            .map(str::to_owned);
        self.params.clear();
        for (key, value) in &node.props {
            if let Some(key) = key.strip_prefix("phx-value-") {
                self.params.insert(key.to_owned(), value.clone());
            }
        }
    }
}

struct TargetIvars {
    data: RefCell<EventDeclaration>,
    key: Rc<str>,
    lifecycle: Rc<Lifecycle>,
    source: Cell<usize>,
    alive: Cell<bool>,
    suppress: Cell<bool>,
    selection: Cell<NSRange>,
}

define_class!(
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "LiveSidestepControlTarget"]
    #[ivars = TargetIvars]
    struct ControlTarget;

    unsafe impl NSObjectProtocol for ControlTarget {}
    unsafe impl NSTextFieldDelegate for ControlTarget {}

    unsafe impl NSControlTextEditingDelegate for ControlTarget {
        #[unsafe(method(controlTextDidChange:))]
        fn changed(&self, notification: &NSNotification) {
            self.observe_notification(notification);
        }

        #[unsafe(method(controlTextDidBeginEditing:))]
        fn began(&self, notification: &NSNotification) {
            if self.active() {
                self.ivars().lifecycle.active_input.replace(Some(self.ivars().key.clone()));
                self.observe_notification(notification);
            }
        }

        #[unsafe(method(controlTextDidEndEditing:))]
        fn ended(&self, notification: &NSNotification) {
            if !self.active() { return; }
            self.observe_notification(notification);
            let ivars = self.ivars();
            if ivars.lifecycle.active_input.borrow().as_deref() == Some(&*ivars.key) {
                ivars.lifecycle.active_input.replace(None);
            }
            // Sidestep clears marked text after this notification returns.
            // Observe the retired editor once on the next host tick.
            ivars.lifecycle.ended_inputs.borrow_mut().insert(ivars.key.clone());
        }
    }

    impl ControlTarget {
        #[unsafe(method(clicked:))]
        fn clicked(&self, sender: &NSControl) {
            let ivars = self.ivars();
            if pointer(sender) != ivars.source.get() || !self.active() {
                return;
            }
            let event = ivars.data.borrow().event();
            if let Some(event) = event {
                ivars.lifecycle.output.send(event);
            }
        }
    }
);

fn marked_range(editor: &NSText) -> Option<NSRange> {
    // SAFETY: AppKit's field editor implements NSTextInputClient on both
    // native AppKit and the pinned Sidestep implementation.
    let range: NSRange = unsafe { msg_send![editor, markedRange] };
    (range.location < isize::MAX as usize).then_some(range)
}

struct EditorSnapshot {
    editor: Option<Retained<NSText>>,
    value: String,
    selection: NSRange,
    marked: Option<NSRange>,
    focused: bool,
}

impl EditorSnapshot {
    fn read(field: &NSTextField, remembered_selection: NSRange, inspect_focus: bool) -> Self {
        if let Some(editor) = field.currentEditor() {
            let value = editor.string().to_string();
            let selection = editor.selectedRange();
            let marked = marked_range(&editor);
            let focused = inspect_focus
                && field
                    .window()
                    .and_then(|window| window.firstResponder())
                    .is_some_and(|responder| pointer(&*responder) == pointer(&*editor));
            Self {
                editor: Some(editor),
                value,
                selection,
                marked,
                focused,
            }
        } else {
            let value = field.stringValue().to_string();
            let length = value.encode_utf16().count();
            let location = remembered_selection.location.min(length);
            let selection =
                NSRange::new(location, remembered_selection.length.min(length - location));
            Self {
                editor: None,
                value,
                selection,
                marked: None,
                focused: false,
            }
        }
    }
}

impl ControlTarget {
    fn new(
        node: &Node,
        generation: u64,
        revision: u64,
        lifecycle: Rc<Lifecycle>,
        mtm: MainThreadMarker,
    ) -> Retained<Self> {
        let input = node.kind == "input";
        let mut data = EventDeclaration {
            id: node.id.clone(),
            kind: if input { "change" } else { "click" },
            incarnation: incarnation(node),
            generation,
            revision,
            name: None,
            params: Map::new(),
            text: input
                .then(|| TextState::new(string(node, "value").to_owned(), edit_revision(node))),
        };
        data.update_properties(node);
        let this = Self::alloc(mtm).set_ivars(TargetIvars {
            data: RefCell::new(data),
            key: Rc::from(node.id.as_str()),
            lifecycle,
            source: Cell::new(0),
            alive: Cell::new(true),
            suppress: Cell::new(false),
            selection: Cell::new(NSRange::new(0, 0)),
        });
        // SAFETY: NSObject's initializer, with all Rust ivars established.
        unsafe { msg_send![super(this), init] }
    }

    fn active(&self) -> bool {
        let ivars = self.ivars();
        ivars.alive.get() && !ivars.suppress.get() && !ivars.lifecycle.closed.get()
    }

    fn observe_notification(&self, notification: &NSNotification) {
        if !self.active() {
            return;
        }
        if let Some(object) = notification.object()
            && pointer(&*object) == self.ivars().source.get()
            && let Ok(field) = object.downcast::<NSTextField>()
        {
            self.observe(&field);
        }
    }

    fn observe(&self, field: &NSTextField) {
        if !self.active() {
            return;
        }
        // No Rust data borrow is held across an Objective-C call. In
        // particular validateEditing/currentEditor may invoke a delegate.
        let snapshot = EditorSnapshot::read(field, self.ivars().selection.get(), false);
        self.ivars().selection.set(snapshot.selection);
        if snapshot.value.len() > MAX_TEXT_BYTES || snapshot.value.contains('\0') {
            self.ivars()
                .lifecycle
                .close("native input exceeds the protocol text limit");
            return;
        }
        let (event, replacement) = {
            let mut data = self.ivars().data.borrow_mut();
            let Some(text) = data.text.as_mut() else {
                return;
            };
            let observation = match text.observe(&snapshot.value, snapshot.marked.is_some()) {
                Ok(observation) => observation,
                Err(reason) => {
                    drop(data);
                    self.ivars().lifecycle.close(reason);
                    return;
                }
            };
            let replacement = observation.replace.then(|| text.value.clone());
            let event = observation.changed.then(|| data.event()).flatten();
            (event, replacement)
        };
        if let Some(value) = replacement {
            self.replace_native(field, &snapshot, &value);
        }
        if let Some(event) = event {
            self.ivars().lifecycle.output.send(event);
        }
    }

    fn replace_native(&self, field: &NSTextField, snapshot: &EditorSnapshot, value: &str) {
        if snapshot.value == value {
            return;
        }
        let selection = selection_after_replacement(
            &snapshot.value,
            value,
            [snapshot.selection.location, snapshot.selection.length],
        );
        let string = NSString::from_str(value);
        self.ivars().suppress.set(true);
        if let Some(editor) = &snapshot.editor {
            // NSControl.setStringValue aborts the active editor in upstream
            // AppKit. Change its cell and the existing editor instead, keeping
            // the native session, first responder, clipboard and selection.
            if let Some(cell) = field.cell() {
                cell.setStringValue(&string);
            }
            editor.setString(&string);
            let selection = NSRange::new(selection[0], selection[1]);
            editor.setSelectedRange(selection);
            editor.scrollRangeToVisible(selection);
            self.ivars().selection.set(selection);
        } else {
            field.setStringValue(&string);
            self.ivars()
                .selection
                .set(NSRange::new(selection[0], selection[1]));
        }
        NSView::setNeedsDisplay(field, true);
        self.ivars().suppress.set(false);
    }

    fn context(&self, node: &Node, generation: u64, revision: u64, properties_changed: bool) {
        let mut data = self.ivars().data.borrow_mut();
        if data.generation != generation
            && let Some(text) = &mut data.text
        {
            text.new_generation();
        }
        data.generation = generation;
        data.revision = revision;
        if properties_changed {
            data.update_properties(node);
        }
    }

    fn reconcile(&self, field: &NSTextField, node: &Node) {
        let snapshot = EditorSnapshot::read(field, self.ivars().selection.get(), false);
        self.ivars().selection.set(snapshot.selection);
        let replacement = {
            let mut data = self.ivars().data.borrow_mut();
            let text = data.text.as_mut().expect("input has text state");
            text.reconcile(string(node, "value"), edit_revision(node))
                .then(|| text.value.clone())
        };
        if let Some(value) = replacement {
            self.replace_native(field, &snapshot, &value);
        }
    }

    fn replay(&self, acknowledgement: u64) {
        if !self.active() {
            return;
        }
        let event = {
            let data = self.ivars().data.borrow();
            data.text
                .as_ref()
                .filter(|text| text.needs_replay(acknowledgement))
                .and_then(|_| data.event())
        };
        if let Some(event) = event {
            self.ivars().lifecycle.output.send(event);
        }
    }
}

enum ControlView {
    Container(Retained<Page>),
    Text(Retained<NSTextField>),
    Button(Retained<NSButton>),
    Input(Retained<NSTextField>),
}

pub struct NativeNode {
    pub node: Node,
    pub layout_frame: Cell<NSRect>,
    view: ControlView,
    target: Option<Retained<ControlTarget>>,
    pub intrinsic: Cell<NSSize>,
}

impl NativeNode {
    pub fn new(
        node: &Node,
        generation: u64,
        revision: u64,
        lifecycle: Rc<Lifecycle>,
        mtm: MainThreadMarker,
    ) -> Self {
        let target = matches!(node.kind.as_str(), "button" | "input")
            .then(|| ControlTarget::new(node, generation, revision, lifecycle, mtm));
        let view = match node.kind.as_str() {
            "column" | "row" | "list" => {
                ControlView::Container(Page::new(mtm, rect(0.0, 0.0, 1.0, 1.0)))
            }
            "text" => {
                let field = NSTextField::wrappingLabelWithString(
                    &NSString::from_str(string(node, "text")),
                    mtm,
                );
                field.setMaximumNumberOfLines(0);
                ControlView::Text(field)
            }
            "button" => {
                let target = target.as_ref().expect("button target");
                // SAFETY: the retained per-control target outlives its button,
                // and clicked: has NSControl's target/action signature.
                let button: Retained<NativeButton> = unsafe {
                    msg_send![NativeButton::class(),
                        buttonWithTitle: &*NSString::from_str(string(node, "text")),
                        target: Some(&**target),
                        action: Some(sel!(clicked:))]
                };
                let button = Retained::into_super(button);
                target.ivars().source.set(pointer(&*button));
                ControlView::Button(button)
            }
            "input" => {
                // The upstream convenience factory always allocates NSTextField,
                // ignoring its receiver class. Initialize our actual subclass.
                // SAFETY: an NSTextField subclass, initialized on the main thread.
                let field: Retained<NativeInput> =
                    unsafe { msg_send![NativeInput::alloc(mtm), initWithFrame: NSRect::ZERO] };
                let field = Retained::into_super(field);
                field.setLineBreakMode(NSLineBreakMode::ByClipping);
                if let Some(cell) = field.cell() {
                    cell.setScrollable(true);
                    cell.setSendsActionOnEndEditing(true);
                }
                field.setStringValue(&NSString::from_str(string(node, "value")));
                field.setPlaceholderString(Some(&NSString::from_str(string(node, "placeholder"))));
                let target = target.as_ref().expect("input target");
                target.ivars().source.set(pointer(&*field));
                // SAFETY: NativeNode retains the delegate for the field's
                // entire lifetime and removes it before releasing either.
                unsafe { field.setDelegate(Some(ProtocolObject::from_ref(&**target))) };
                ControlView::Input(field)
            }
            _ => unreachable!("the protocol validates node kinds"),
        };
        let result = Self {
            node: node.clone(),
            view,
            target,
            intrinsic: Cell::new(NSSize::ZERO),
            layout_frame: Cell::new(NSRect::ZERO),
        };
        result.measure_intrinsic();
        result
    }

    pub fn view(&self) -> &NSView {
        match &self.view {
            ControlView::Container(view) => view,
            ControlView::Text(view) | ControlView::Input(view) => view,
            ControlView::Button(view) => view,
        }
    }

    pub fn compatible(&self, node: &Node) -> bool {
        self.node.kind == node.kind && incarnation(&self.node) == incarnation(node)
    }

    pub fn context(&self, node: &Node, generation: u64, revision: u64) {
        if let Some(target) = &self.target {
            target.context(node, generation, revision, self.node.props != node.props);
        }
    }

    pub fn update(&mut self, node: &Node) {
        match &self.view {
            ControlView::Text(field) if string(&self.node, "text") != string(node, "text") => {
                field.setStringValue(&NSString::from_str(string(node, "text")));
            }
            ControlView::Button(button) if string(&self.node, "text") != string(node, "text") => {
                button.setTitle(&NSString::from_str(string(node, "text")));
            }
            ControlView::Input(field) => {
                if string(&self.node, "placeholder") != string(node, "placeholder") {
                    field.setPlaceholderString(Some(&NSString::from_str(string(
                        node,
                        "placeholder",
                    ))));
                }
                if string(&self.node, "value") != string(node, "value")
                    || edit_revision(&self.node) != edit_revision(node)
                {
                    self.target
                        .as_ref()
                        .expect("input target")
                        .reconcile(field, node);
                }
            }
            _ => {}
        }
        if self.node != *node {
            self.node = node.clone();
            self.measure_intrinsic();
        }
    }

    fn measure_intrinsic(&self) {
        let size = match &self.view {
            ControlView::Text(field) => field
                .cell()
                .map_or(NSSize::new(1.0, 20.0), |cell| cell.cellSize()),
            ControlView::Button(button) => {
                let size = button
                    .cell()
                    .map_or(NSSize::new(72.0, 32.0), |cell| cell.cellSize());
                NSSize::new(size.width.max(72.0), size.height.max(32.0))
            }
            ControlView::Input(field) => {
                let height = field.intrinsicContentSize().height.max(28.0);
                NSSize::new(300.0, height)
            }
            ControlView::Container(_) => NSSize::ZERO,
        };
        self.intrinsic.set(NSSize::new(
            size.width.max(1.0).ceil(),
            size.height.max(1.0).ceil(),
        ));
    }

    pub fn measure_height(&self, width: f64) -> f64 {
        match &self.view {
            ControlView::Text(field) => field
                .sizeThatFits(NSSize::new(width, f64::MAX))
                .height
                .max(18.0)
                .ceil(),
            _ => self.intrinsic.get().height,
        }
    }

    pub fn observe_input(&self) {
        if let ControlView::Input(field) = &self.view {
            self.target.as_ref().expect("input target").observe(field);
        }
    }

    pub fn poll_composition(&self) {
        if let ControlView::Input(field) = &self.view {
            let target = self.target.as_ref().expect("input target");
            let composing = target
                .ivars()
                .data
                .borrow()
                .text
                .as_ref()
                .is_some_and(TextState::composing);
            if composing
                && field
                    .currentEditor()
                    .is_none_or(|editor| marked_range(&editor).is_none())
            {
                target.observe(field);
            }
        }
    }

    pub fn replay(&self) {
        if matches!(&self.view, ControlView::Input(_)) {
            self.target
                .as_ref()
                .expect("input target")
                .replay(edit_revision(&self.node));
        }
    }

    pub fn inspect(&self, content: &NSView) -> Value {
        // Diagnostics use top-left window-content coordinates, not the
        // parent's local frame, and account for the native clip view's scroll.
        let mut frame = self
            .view()
            .convertRect_toView(self.view().bounds(), Some(content));
        if !content.isFlipped() {
            frame.origin.y = content.bounds().size.height - frame.origin.y - frame.size.height;
        }
        let mut inspection = json!({
            "kind":self.node.kind, "incarnation":incarnation(&self.node),
            "entity":pointer(self.view()) as u64, "children":self.node.children,
            "frame":[frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
        });
        match &self.view {
            ControlView::Input(field) => {
                let target = self.target.as_ref().expect("input target");
                let snapshot = EditorSnapshot::read(field, target.ivars().selection.get(), true);
                let data = target.ivars().data.borrow();
                let text = data.text.as_ref().expect("input text state");
                inspection["value"] = json!(snapshot.value);
                inspection["edit_revision"] = json!(text.revision);
                inspection["acknowledged_revision"] = json!(text.acknowledged);
                inspection["selection"] =
                    json!([snapshot.selection.location, snapshot.selection.length]);
                inspection["marked"] = snapshot
                    .marked
                    .map_or(Value::Null, |range| json!([range.location, range.length]));
                inspection["focused"] = json!(snapshot.focused);
            }
            ControlView::Text(field) => inspection["text"] = json!(field.stringValue().to_string()),
            ControlView::Button(button) => inspection["text"] = json!(button.title().to_string()),
            ControlView::Container(_) => {}
        }
        inspection
    }

    pub fn retire(&self) {
        if let Some(target) = &self.target {
            target.ivars().alive.set(false);
            let lifecycle = &target.ivars().lifecycle;
            if lifecycle.active_input.borrow().as_deref() == Some(&*target.ivars().key) {
                lifecycle.active_input.replace(None);
            }
            lifecycle
                .ended_inputs
                .borrow_mut()
                .remove(&target.ivars().key);
        }
        if let ControlView::Input(field) = &self.view {
            // SAFETY: nil removes the weak delegate before the target goes.
            unsafe { field.setDelegate(None) };
        }
        if let ControlView::Button(button) = &self.view {
            // SAFETY: nil removes the weak target before it goes.
            unsafe {
                button.setTarget(None);
                button.setAction(None);
            }
        }
        self.view().removeFromSuperview();
    }
}
