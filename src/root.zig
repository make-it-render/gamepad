//! mir-gamepad — cross-platform gamepad input library.
//!
//! Usage:
//!
//!     var ctx = try gamepad.Context.init(allocator, .{});
//!     defer ctx.deinit();
//!
//!     // Each frame:
//!     while (ctx.poll()) |event| {
//!         switch (event) {
//!             .connected    => |id| ...,
//!             .disconnected => |id| ...,
//!             .button_pressed  => |e| ..., // e.id, e.button
//!             .button_released => |e| ...,
//!             .axis_moved      => |e| ..., // e.id, e.axis, e.value
//!         }
//!     }
//!
//!     // Or query state directly:
//!     if (ctx.get(0)) |pad| {
//!         const x = pad.axis(.left_stick_x);
//!         const jump = pad.button(.south);
//!     }

const builtin = @import("builtin");
const common = @import("common.zig");

pub const Button = common.Button;
pub const Axis = common.Axis;
pub const Event = common.Event;
pub const State = common.State;
pub const Id = common.Id;
pub const Options = common.Options;
pub const max_gamepads = common.max_gamepads;

/// The platform-specific backend. Currently Linux (evdev); Windows (xinput)
/// and Steam Input are planned.
pub const Context = switch (builtin.os.tag) {
    .linux => @import("evdev.zig").Context,
    .windows => @import("xinput.zig").Context,
    else => @compileError("mir-gamepad: unsupported platform"),
};

test {
    _ = common;
    if (builtin.os.tag == .linux) {
        _ = @import("evdev.zig");
    }
    if (builtin.os.tag == .windows) {
        _ = @import("xinput.zig");
    }
}
