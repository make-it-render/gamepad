//! Platform-independent gamepad types.
//!
//! These types are shared across all backends (evdev, xinput, steam) and form
//! the public API of the library. They use positional names (south, east, ...)
//! rather than vendor-specific labels (A, B, X, Y) so they work for any
//! controller.

/// A gamepad slot identifier. Supports up to 16 simultaneous gamepads.
pub const Id = u4;

/// Maximum number of gamepads that can be tracked at once.
pub const max_gamepads = 16;

/// Gamepad buttons, named by physical position on a standard controller.
///
/// Positional naming avoids confusion between vendors:
///
///            Xbox    PlayStation    Nintendo
///   south      A       Cross          B
///   east       B       Circle         A
///   west       X       Square         Y
///   north      Y       Triangle       X
///
pub const Button = enum(u8) {
    // Face buttons (right cluster).
    south,
    east,
    west,
    north,

    // Shoulder buttons.
    left_bumper, // LB / L1
    right_bumper, // RB / R1

    // Center buttons.
    back, // Select / Back / Share / Minus
    start, // Start / Menu / Options / Plus
    guide, // Home / Xbox / PS

    // Stick clicks.
    left_stick, // L3
    right_stick, // R3

    // D-pad.
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,

    pub const count = @typeInfo(Button).@"enum".fields.len;
};

/// Analog axes. Sticks range from -1 to 1, triggers from 0 to 1.
pub const Axis = enum(u8) {
    left_stick_x, // -1 (left)  .. 1 (right)
    left_stick_y, // -1 (up)    .. 1 (down)
    right_stick_x, // -1 (left)  .. 1 (right)
    right_stick_y, // -1 (up)    .. 1 (down)
    left_trigger, //  0 (rest)  .. 1 (fully pressed)
    right_trigger, //  0 (rest)  .. 1 (fully pressed)

    pub const count = @typeInfo(Axis).@"enum".fields.len;
};

/// A gamepad event. Returned by `Context.poll()`.
///
/// Events are emitted only when state actually changes: you will never get
/// two consecutive `button_pressed` events for the same button without a
/// `button_released` in between.
pub const Event = union(enum) {
    connected: Id,
    disconnected: Id,
    button_pressed: struct { id: Id, button: Button },
    button_released: struct { id: Id, button: Button },
    axis_moved: struct { id: Id, axis: Axis, value: f32 },
};

/// Snapshot of a gamepad's current state. Handy for direct queries when
/// you don't need to react to every individual event.
pub const State = struct {
    buttons: [Button.count]bool = .{false} ** Button.count,
    axes: [Axis.count]f32 = .{0} ** Axis.count,

    /// Returns true if the given button is currently held down.
    pub fn button(self: *const State, b: Button) bool {
        return self.buttons[@intFromEnum(b)];
    }

    /// Returns the current value of an analog axis.
    pub fn axis(self: *const State, a: Axis) f32 {
        return self.axes[@intFromEnum(a)];
    }
};

/// Configuration options passed to `Context.init()`.
pub const Options = struct {
    /// Analog stick deadzone threshold (0.0 – 1.0). Axis values with a
    /// magnitude below this are snapped to zero. Default is 0.2.
    deadzone: f32 = 0.2,
};
