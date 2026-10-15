use crate::controls::{NativeNode, rect};
use live_sidestep_protocol::Tree;
use objc2_app_kit::NSView;
use objc2_foundation::NSSize;
use std::collections::BTreeMap;

const MARGIN: f64 = 16.0;

fn gap(node: &NativeNode) -> f64 {
    node.node
        .props
        .get("gap")
        .and_then(serde_json::Value::as_u64)
        .unwrap_or(8) as f64
}

/// Cache unconstrained preferred sizes once after reconciliation. A resize
/// subsequently visits each view once, without rebuilding/reparenting controls.
pub fn update_intrinsics(tree: &Tree, nodes: &BTreeMap<String, NativeNode>) {
    fn measure(id: &str, nodes: &BTreeMap<String, NativeNode>) -> NSSize {
        let node = &nodes[id];
        if !matches!(node.node.kind.as_str(), "column" | "row" | "list") {
            return node.intrinsic.get();
        }
        let mut width: f64 = 0.0;
        let mut height: f64 = 0.0;
        let horizontal = node.node.kind == "row";
        for (index, child) in node.node.children.iter().enumerate() {
            let size = measure(child, nodes);
            if horizontal {
                width += size.width + if index == 0 { 0.0 } else { gap(node) };
                height = height.max(size.height);
            } else {
                width = width.max(size.width);
                height += size.height + if index == 0 { 0.0 } else { gap(node) };
            }
        }
        let size = NSSize::new(width.max(1.0), height.max(1.0));
        node.intrinsic.set(size);
        size
    }
    measure(&tree.root, nodes);
}

pub fn place(
    tree: &Tree,
    nodes: &BTreeMap<String, NativeNode>,
    document: &NSView,
    viewport: NSSize,
) {
    fn stage_frame(node: &NativeNode, x: f64, y: f64, width: f64, height: f64) {
        node.layout_frame
            .set(rect(x, y, width.max(1.0), height.max(1.0)));
    }

    fn center_line(
        children: &[String],
        nodes: &BTreeMap<String, NativeNode>,
        top: f64,
        height: f64,
    ) {
        for id in children {
            let node = &nodes[id];
            let mut frame = node.layout_frame.get();
            frame.origin.y = top + (height - frame.size.height) / 2.0;
            node.layout_frame.set(frame);
        }
    }

    fn place_node(
        id: &str,
        nodes: &BTreeMap<String, NativeNode>,
        x: f64,
        y: f64,
        offered: f64,
    ) -> NSSize {
        let node = &nodes[id];
        let offered = offered.max(1.0);
        match node.node.kind.as_str() {
            "column" | "list" => {
                let mut child_y = 0.0;
                for (index, child) in node.node.children.iter().enumerate() {
                    if index != 0 {
                        child_y += gap(node);
                    }
                    child_y += place_node(child, nodes, 0.0, child_y, offered).height;
                }
                let height = child_y.max(1.0);
                stage_frame(node, x, y, offered, height);
                NSSize::new(offered, height)
            }
            "row" => {
                let mut child_x: f64 = 0.0;
                let mut child_y: f64 = 0.0;
                let mut row_height: f64 = 0.0;
                let mut line_start = 0;
                for (index, child) in node.node.children.iter().enumerate() {
                    let width = nodes[child].intrinsic.get().width.min(offered).max(1.0);
                    if child_x > 0.0 && child_x + gap(node) + width > offered {
                        center_line(
                            &node.node.children[line_start..index],
                            nodes,
                            child_y,
                            row_height,
                        );
                        line_start = index;
                        child_x = 0.0;
                        child_y += row_height + gap(node);
                        row_height = 0.0;
                    }
                    if child_x > 0.0 {
                        child_x += gap(node);
                    }
                    let size = place_node(child, nodes, child_x, child_y, width);
                    child_x += size.width;
                    row_height = row_height.max(size.height);
                }
                center_line(
                    &node.node.children[line_start..],
                    nodes,
                    child_y,
                    row_height,
                );
                let height = (child_y + row_height).max(1.0);
                stage_frame(node, x, y, offered, height);
                NSSize::new(offered, height)
            }
            "text" => {
                let height = node.measure_height(offered);
                stage_frame(node, x, y, offered, height);
                NSSize::new(offered, height)
            }
            "input" | "button" => {
                let size = node.intrinsic.get();
                let width = size.width.min(offered).max(1.0);
                stage_frame(node, x, y, width, size.height);
                NSSize::new(width, size.height)
            }
            _ => unreachable!("the protocol validates node kinds"),
        }
    }

    let width = (viewport.width - MARGIN * 2.0).max(1.0);
    let root = place_node(&tree.root, nodes, MARGIN, MARGIN, width);
    let size = NSSize::new(
        viewport.width.max(1.0),
        viewport.height.max(root.height + MARGIN * 2.0),
    );
    if document.frame().size != size {
        document.setFrameSize(size);
    }
    // Apply each final frame once; centering must not transiently move editors
    // to a line's top and then move them again.
    for node in nodes.values() {
        let frame = node.layout_frame.get();
        let view = node.view();
        if view.frame() != frame {
            view.setFrame(frame);
        }
    }
}
