//! Keep compositor-owned pointer and keyboard capabilities alive for Wayland
//! acceptance. Headless sway has no physical devices: cursor IPC alone exposes
//! no pointer and transient keyboards can lose their first key while clients
//! bind. Actual input still travels through swaymsg/wtype and the compositor.

use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::os::fd::AsFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use wayland_client::protocol::{wl_registry, wl_seat};
use wayland_client::{Connection, Dispatch, QueueHandle, delegate_noop};
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::{
    zwp_virtual_keyboard_manager_v1, zwp_virtual_keyboard_v1,
};
use wayland_protocols_wlr::virtual_pointer::v1::client::{
    zwlr_virtual_pointer_manager_v1, zwlr_virtual_pointer_v1,
};

#[derive(Default)]
struct Seat {
    manager: Option<zwlr_virtual_pointer_manager_v1::ZwlrVirtualPointerManagerV1>,
    keyboard_manager: Option<zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1>,
    seat: Option<wl_seat::WlSeat>,
}

impl Dispatch<wl_registry::WlRegistry, ()> for Seat {
    fn event(
        state: &mut Self,
        registry: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global {
            name,
            interface,
            version,
        } = event
        {
            match interface.as_str() {
                "zwlr_virtual_pointer_manager_v1" => {
                    state.manager = Some(registry.bind(name, version.min(2), qh, ()));
                }
                "zwp_virtual_keyboard_manager_v1" => {
                    state.keyboard_manager = Some(registry.bind(name, 1, qh, ()));
                }
                "wl_seat" if state.seat.is_none() => {
                    state.seat = Some(registry.bind(name, version.min(7), qh, ()));
                }
                _ => {}
            }
        }
    }
}

delegate_noop!(Seat: ignore wl_seat::WlSeat);
delegate_noop!(Seat: ignore zwlr_virtual_pointer_manager_v1::ZwlrVirtualPointerManagerV1);
delegate_noop!(Seat: ignore zwlr_virtual_pointer_v1::ZwlrVirtualPointerV1);
delegate_noop!(Seat: ignore zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1);
delegate_noop!(Seat: ignore zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1);

fn main() {
    let connection = Connection::connect_to_env().expect("Wayland compositor connection");
    let mut queue = connection.new_event_queue();
    let handle = queue.handle();
    let _registry = connection.display().get_registry(&handle, ());
    let mut seat = Seat::default();
    queue.roundtrip(&mut seat).expect("Wayland global registry");
    let manager = seat
        .manager
        .as_ref()
        .expect("compositor virtual-pointer protocol");
    let pointer = manager.create_virtual_pointer(seat.seat.as_ref(), &handle, ());
    let keyboard = seat
        .keyboard_manager
        .as_ref()
        .expect("compositor virtual-keyboard protocol")
        .create_virtual_keyboard(seat.seat.as_ref().expect("compositor seat"), &handle, ());
    let path =
        PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").expect("private runtime directory"))
            .join(format!("sidestep-keymap-{}.xkb", std::process::id()));
    let mut keymap = OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .expect("temporary keyboard mapping");
    const KEYMAP: &[u8] = b"xkb_keymap { xkb_keycodes { include \"evdev+aliases(qwerty)\" }; xkb_types { include \"complete\" }; xkb_compatibility { include \"complete\" }; xkb_symbols { include \"pc+us+inet(evdev)\" }; };\0";
    keymap.write_all(KEYMAP).expect("keyboard mapping");
    keyboard.keymap(1, keymap.as_fd(), KEYMAP.len() as u32);
    queue
        .roundtrip(&mut seat)
        .expect("persistent compositor pointer");
    std::fs::remove_file(path).expect("remove keyboard mapping");
    println!("WAYLAND_SEAT_READY");
    std::io::stdout().flush().expect("seat readiness output");
    let _ = std::io::stdin().read(&mut [0u8; 1]);
    pointer.destroy();
    keyboard.destroy();
    let _ = connection.flush();
}
