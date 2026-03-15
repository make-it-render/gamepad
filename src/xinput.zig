//! Windows XInput backend.
//!
//! XInput is the standard Windows API for Xbox-compatible gamepads. It supports
//! exactly 4 controllers (slots 0–3), each identified by its slot index.
//!
//! The DLL is loaded dynamically at runtime — no link-time Windows SDK dependency
//! — so the library cross-compiles from any host. We try `xinput1_4.dll` (Win 8+)
//! first, falling back to `xinput9_1_0.dll` (Vista+).
//!
//! Disconnected slots are probed at most once every 2 seconds to avoid the
//! overhead of calling `XInputGetState` on empty slots every frame.

const std = @import("std");
const common = @import("common.zig");

const Button = common.Button;
const Axis = common.Axis;
const Event = common.Event;
const State = common.State;
const Id = common.Id;
const Options = common.Options;

const log = std.log.scoped(.xinput);
const windows = std.os.windows;
const DWORD = windows.DWORD;
const HMODULE = windows.HMODULE;

// ── XInput ABI types ────────────────────────────────────────────────────────
//
// These match the C definitions from <Xinput.h>. The struct layouts must be
// exact (`extern struct`) so we can pass pointers directly to the DLL.

const XINPUT_GAMEPAD = extern struct {
    wButtons: u16,
    bLeftTrigger: u8,
    bRightTrigger: u8,
    sThumbLX: i16,
    sThumbLY: i16,
    sThumbRX: i16,
    sThumbRY: i16,
};

const XINPUT_STATE = extern struct {
    dwPacketNumber: DWORD,
    Gamepad: XINPUT_GAMEPAD,
};

// ── XInput constants ────────────────────────────────────────────────────────

const XI_DPAD_UP: u16 = 0x0001;
const XI_DPAD_DOWN: u16 = 0x0002;
const XI_DPAD_LEFT: u16 = 0x0004;
const XI_DPAD_RIGHT: u16 = 0x0008;
const XI_START: u16 = 0x0010;
const XI_BACK: u16 = 0x0020;
const XI_LEFT_THUMB: u16 = 0x0040;
const XI_RIGHT_THUMB: u16 = 0x0080;
const XI_LEFT_SHOULDER: u16 = 0x0100;
const XI_RIGHT_SHOULDER: u16 = 0x0200;
// Guide button (0x0400) is not available through the standard XInput API.
const XI_A: u16 = 0x1000;
const XI_B: u16 = 0x2000;
const XI_X: u16 = 0x4000;
const XI_Y: u16 = 0x8000;

const ERROR_SUCCESS: DWORD = 0;

/// Probe interval for disconnected slots: 2 seconds in nanoseconds.
const PROBE_INTERVAL_NS: u64 = 2 * std.time.ns_per_s;

// ── DLL loading ─────────────────────────────────────────────────────────────

const XInputGetStateFn = *const fn (DWORD, *XINPUT_STATE) callconv(.winapi) DWORD;

const DllInfo = struct {
    handle: HMODULE,
    get_state: XInputGetStateFn,
};

/// Load the XInput DLL from the system.
/// NOTE: Uses default DLL search order. For hardened environments, consider
/// using LoadLibraryExW with LOAD_LIBRARY_SEARCH_SYSTEM32 to prevent
/// DLL hijacking from the current directory.
fn load_xinput() !DllInfo {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;

    const handle = windows.LoadLibraryW(L("xinput1_4.dll")) catch
        windows.LoadLibraryW(L("xinput9_1_0.dll")) catch
        return error.XInputNotFound;
    errdefer _ = windows.kernel32.FreeLibrary(handle);

    const proc = windows.kernel32.GetProcAddress(handle, "XInputGetState") orelse
        return error.XInputNotFound;

    return .{
        .handle = handle,
        .get_state = @ptrCast(proc),
    };
}

// ── per-slot bookkeeping ────────────────────────────────────────────────────

const Slot = struct {
    connected: bool = false,
    packet_number: DWORD = 0,
    state: State = .{},
};

// ── public API ──────────────────────────────────────────────────────────────

/// XInput gamepad context for Windows.
/// NOT thread-safe — all calls (init, poll, deinit) must happen from the same thread.
pub const Context = struct {
    allocator: std.mem.Allocator,
    options: Options,
    slots: [4]Slot,
    dll_handle: HMODULE,
    get_state_fn: XInputGetStateFn,
    event_buf: std.ArrayListUnmanaged(Event),
    event_pos: usize,
    last_probe: ?std.time.Instant,

    /// Set up the gamepad subsystem: load the XInput DLL and probe all 4 slots.
    pub fn init(allocator: std.mem.Allocator, options: Options) !@This() {
        const dll = try load_xinput();

        var self = @This(){
            .allocator = allocator,
            .options = options,
            .slots = [1]Slot{.{}} ** 4,
            .dll_handle = dll.handle,
            .get_state_fn = dll.get_state,
            .event_buf = .empty,
            .event_pos = 0,
            .last_probe = null,
        };

        // Probe all 4 slots for already-connected controllers.
        self.poll_slots();

        return self;
    }

    /// Free the event buffer, unload the XInput DLL, and poison the struct.
    pub fn deinit(self: *@This()) void {
        self.event_buf.deinit(self.allocator);
        _ = windows.kernel32.FreeLibrary(self.dll_handle);
        self.* = undefined;
    }

    /// Return the next pending event, or null if there are none.
    ///
    /// Call this in a loop each frame:
    ///
    ///     while (ctx.poll()) |event| { ... }
    ///
    /// The first call polls all 4 XInput slots and buffers any resulting
    /// events. Subsequent calls drain the buffer without additional DLL calls.
    pub fn poll(self: *@This()) ?Event {
        // Drain buffered events first.
        if (self.event_pos < self.event_buf.items.len) {
            defer self.event_pos += 1;
            return self.event_buf.items[self.event_pos];
        }

        // Buffer empty — do a new poll cycle.
        self.event_buf.clearRetainingCapacity();
        self.event_pos = 0;
        self.poll_slots();

        if (self.event_pos < self.event_buf.items.len) {
            defer self.event_pos += 1;
            return self.event_buf.items[self.event_pos];
        }
        return null;
    }

    /// Look up a connected gamepad by ID. Returns its current button/axis
    /// state, or null if no gamepad with that ID is connected.
    pub fn get(self: *const @This(), id: Id) ?*const State {
        if (id >= 4) return null;
        const slot = &self.slots[id];
        if (!slot.connected) return null;
        return &slot.state;
    }

    // ── internal: polling ───────────────────────────────────────────────

    /// Poll all 4 XInput slots. Connected slots are polled every call;
    /// disconnected slots are only probed when the probe interval has
    /// elapsed.
    fn poll_slots(self: *@This()) void {
        const now = std.time.Instant.now() catch null;
        const should_probe = if (self.last_probe) |last| blk: {
            const n = now orelse break :blk true;
            break :blk n.since(last) >= PROBE_INTERVAL_NS;
        } else true;

        for (0..4) |i| {
            const slot = &self.slots[i];

            if (!slot.connected and !should_probe) continue;

            var xi_state: XINPUT_STATE = undefined;
            const result = self.get_state_fn(@intCast(i), &xi_state);

            if (result == ERROR_SUCCESS) {
                if (!slot.connected) {
                    // Newly connected.
                    slot.connected = true;
                    slot.packet_number = xi_state.dwPacketNumber;
                    const id: Id = @intCast(i);
                    self.emit(.{ .connected = id });
                    self.sync_state(id, slot, &xi_state.Gamepad);
                } else if (xi_state.dwPacketNumber != slot.packet_number) {
                    // State changed.
                    slot.packet_number = xi_state.dwPacketNumber;
                    self.sync_state(@intCast(i), slot, &xi_state.Gamepad);
                }
            } else if (slot.connected) {
                // Disconnected.
                slot.connected = false;
                slot.packet_number = 0;
                slot.state = .{};
                self.emit(.{ .disconnected = @as(Id, @intCast(i)) });
            }
        }

        if (should_probe) {
            self.last_probe = now;
        }
    }

    // ── internal: state synchronization ─────────────────────────────────

    /// Compare a fresh XInput state against the stored state and emit
    /// events for anything that changed.
    fn sync_state(self: *@This(), id: Id, slot: *Slot, gp: *const XINPUT_GAMEPAD) void {
        // Buttons.
        for (button_map) |entry| {
            const pressed = (gp.wButtons & entry.mask) != 0;
            const idx = @intFromEnum(entry.button);
            if (slot.state.buttons[idx] != pressed) {
                slot.state.buttons[idx] = pressed;
                self.emit(if (pressed)
                    .{ .button_pressed = .{ .id = id, .button = entry.button } }
                else
                    .{ .button_released = .{ .id = id, .button = entry.button } });
            }
        }

        // Triggers (simple threshold deadzone).
        self.sync_trigger(id, slot, .left_trigger, gp.bLeftTrigger);
        self.sync_trigger(id, slot, .right_trigger, gp.bRightTrigger);

        // Sticks (radial deadzone, Y-axis inverted).
        self.sync_stick_pair(id, slot, gp.sThumbLX, gp.sThumbLY, .left_stick_x, .left_stick_y);
        self.sync_stick_pair(id, slot, gp.sThumbRX, gp.sThumbRY, .right_stick_x, .right_stick_y);
    }

    fn sync_trigger(self: *@This(), id: Id, slot: *Slot, axis: Axis, raw: u8) void {
        const value = common.apply_trigger_deadzone(
            @as(f32, @floatFromInt(raw)) / 255.0,
            self.options.deadzone,
        );
        const idx = @intFromEnum(axis);
        if (slot.state.axes[idx] != value) {
            slot.state.axes[idx] = value;
            self.emit(.{ .axis_moved = .{ .id = id, .axis = axis, .value = value } });
        }
    }

    fn sync_stick_pair(
        self: *@This(),
        id: Id,
        slot: *Slot,
        raw_x: i16,
        raw_y: i16,
        axis_x: Axis,
        axis_y: Axis,
    ) void {
        // Normalize to -1..1, negate Y (XInput: up=positive, our API: up=negative).
        const nx = normalize_stick_axis(raw_x);
        const ny = -normalize_stick_axis(raw_y);

        // Apply radial deadzone.
        const dz = common.apply_radial_deadzone(nx, ny, self.options.deadzone);

        const xi = @intFromEnum(axis_x);
        const yi = @intFromEnum(axis_y);

        if (slot.state.axes[xi] != dz[0]) {
            slot.state.axes[xi] = dz[0];
            self.emit(.{ .axis_moved = .{ .id = id, .axis = axis_x, .value = dz[0] } });
        }
        if (slot.state.axes[yi] != dz[1]) {
            slot.state.axes[yi] = dz[1];
            self.emit(.{ .axis_moved = .{ .id = id, .axis = axis_y, .value = dz[1] } });
        }
    }

    /// Append an event to the buffer. OOM is silently ignored — dropping
    /// an event is better than crashing.
    fn emit(self: *@This(), event: Event) void {
        self.event_buf.append(self.allocator, event) catch {
            log.warn("Event dropped: out of memory", .{});
        };
    }
};

// ── normalization (free functions) ──────────────────────────────────────────

/// Map an i16 thumbstick value to -1.0..1.0.
fn normalize_stick_axis(raw: i16) f32 {
    return std.math.clamp(@as(f32, @floatFromInt(raw)) / 32767.0, -1.0, 1.0);
}


// ── button mapping ──────────────────────────────────────────────────────────

const ButtonMapping = struct {
    mask: u16,
    button: Button,
};

/// Maps XInput button bitmask values to platform-independent Button enums.
/// The guide button is not available through the standard XInput API.
const button_map = [_]ButtonMapping{
    .{ .mask = XI_A, .button = .south },
    .{ .mask = XI_B, .button = .east },
    .{ .mask = XI_X, .button = .west },
    .{ .mask = XI_Y, .button = .north },
    .{ .mask = XI_LEFT_SHOULDER, .button = .left_bumper },
    .{ .mask = XI_RIGHT_SHOULDER, .button = .right_bumper },
    .{ .mask = XI_BACK, .button = .back },
    .{ .mask = XI_START, .button = .start },
    .{ .mask = XI_LEFT_THUMB, .button = .left_stick },
    .{ .mask = XI_RIGHT_THUMB, .button = .right_stick },
    .{ .mask = XI_DPAD_UP, .button = .dpad_up },
    .{ .mask = XI_DPAD_DOWN, .button = .dpad_down },
    .{ .mask = XI_DPAD_LEFT, .button = .dpad_left },
    .{ .mask = XI_DPAD_RIGHT, .button = .dpad_right },
};

// Compile-time check: every Button variant except .guide is in the map.
comptime {
    var covered = [_]bool{false} ** Button.count;
    for (button_map) |entry| {
        covered[@intFromEnum(entry.button)] = true;
    }
    // Guide button is not available through the standard XInput API.
    covered[@intFromEnum(Button.guide)] = true;
    for (covered) |c| {
        if (!c) @compileError("button_map is missing a Button variant");
    }
}

// ── tests ───────────────────────────────────────────────────────────────────

test "XINPUT_GAMEPAD layout" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(XINPUT_GAMEPAD));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(XINPUT_GAMEPAD, "wButtons"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(XINPUT_GAMEPAD, "bLeftTrigger"));
    try std.testing.expectEqual(@as(usize, 3), @offsetOf(XINPUT_GAMEPAD, "bRightTrigger"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(XINPUT_GAMEPAD, "sThumbLX"));
    try std.testing.expectEqual(@as(usize, 6), @offsetOf(XINPUT_GAMEPAD, "sThumbLY"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(XINPUT_GAMEPAD, "sThumbRX"));
    try std.testing.expectEqual(@as(usize, 10), @offsetOf(XINPUT_GAMEPAD, "sThumbRY"));
}

test "XINPUT_STATE layout" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(XINPUT_STATE));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(XINPUT_STATE, "dwPacketNumber"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(XINPUT_STATE, "Gamepad"));
}

test "normalize_stick_axis" {
    const testing = std.testing;
    try testing.expectApproxEqAbs(@as(f32, 0.0), normalize_stick_axis(0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), normalize_stick_axis(32767), 0.001);
    try testing.expectApproxEqAbs(@as(f32, -1.0), normalize_stick_axis(-32768), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), normalize_stick_axis(16383), 0.01);
}

