//! Linux evdev backend.
//!
//! On Linux, gamepads show up as character devices at `/dev/input/eventN`.
//! We read raw `input_event` structs from these files to get button presses
//! and axis movements, and we use `inotify` to detect when gamepads are
//! plugged in or unplugged.
//!
//! Everything here uses raw Linux syscalls — no libc, no libudev — so the
//! library cross-compiles to any Linux target without extra dependencies.

const std = @import("std");
const common = @import("common.zig");

const Button = common.Button;
const Axis = common.Axis;
const Event = common.Event;
const State = common.State;
const Id = common.Id;
const Options = common.Options;

const linux = std.os.linux;
const posix = std.posix;
const log = std.log.scoped(.evdev);

// ── Linux kernel structs ────────────────────────────────────────────────────
//
// These match the C definitions in <linux/input.h>. The kernel writes
// `InputEvent` structs when you read() from an evdev device. Each event
// carries a type (what kind of input), a code (which button/axis), and a
// value (pressed=1 / released=0 for buttons, raw position for axes).

const InputEvent = extern struct {
    tv_sec: isize,
    tv_usec: isize,
    type: u16,
    code: u16,
    value: i32,
};

/// Calibration data for one analog axis, retrieved via `ioctl(EVIOCGABS)`.
/// The kernel reports the hardware's min/max range so we can normalize raw
/// values to -1..1 (sticks) or 0..1 (triggers).
const AbsInfo = extern struct {
    value: i32, // current position
    minimum: i32, // hardware minimum
    maximum: i32, // hardware maximum
    fuzz: i32, // noise filter (unused by us)
    flat: i32, // center deadzone hint (unused — we apply our own)
    resolution: i32, // units per mm (unused)
};

// ── evdev codes ─────────────────────────────────────────────────────────────
//
// These enums mirror the kernel's event type, button, and axis codes from
// <linux/input-event-codes.h>. They are non-exhaustive (`_`) so we can
// safely cast any u16 from the kernel without hitting illegal enum values.

/// Event types we care about. The kernel defines many more (EV_REL,
/// EV_MSC, EV_FF, ...) but gamepads only use these two.
const EvType = enum(u16) {
    key = 0x01, // button press / release
    abs = 0x03, // absolute axis value change
    _, // other event types we ignore
};

/// Evdev button codes. The kernel uses positional names: `south` is the
/// bottom face button ("A" on Xbox, "Cross" on PlayStation).
///
/// `south` is also known as `BTN_GAMEPAD` — its presence in a device's
/// capability bitmask is what identifies the device as a gamepad.
const EvButton = enum(u16) {
    south = 0x130, // BTN_GAMEPAD / BTN_A
    east = 0x131, // BTN_B
    north = 0x134, // BTN_Y (top face button)
    west = 0x133, // BTN_X (left face button)
    tl = 0x136, // left bumper (LB / L1)
    tr = 0x137, // right bumper (RB / R1)
    tl2 = 0x138, // left trigger digital (LT / L2)
    tr2 = 0x139, // right trigger digital (RT / R2)
    select = 0x13a,
    start = 0x13b,
    mode = 0x13c, // guide / home / PS button
    thumbl = 0x13d, // left stick click (L3)
    thumbr = 0x13e, // right stick click (R3)
    dpad_up = 0x220,
    dpad_down = 0x221,
    dpad_left = 0x222,
    dpad_right = 0x223,
    _, // other button codes we don't handle

    /// Highest code we need to probe in capability bitmasks.
    const key_max: u16 = 0x2ff;
};

/// Evdev absolute axis codes.
const EvAxis = enum(u16) {
    x = 0x00, // left stick X
    y = 0x01, // left stick Y
    z = 0x02, // left trigger (analog)
    rx = 0x03, // right stick X
    ry = 0x04, // right stick Y
    rz = 0x05, // right trigger (analog)
    hat0x = 0x10, // D-pad horizontal (-1 = left, 1 = right)
    hat0y = 0x11, // D-pad vertical   (-1 = up,   1 = down)
    _, // other axes we don't handle
};

// ── ioctl encoding ──────────────────────────────────────────────────────────
//
// Linux ioctls pack direction, type, number, and payload size into a u32:
//
//   bits 31-30: direction (2 = read from kernel)
//   bits 29-16: payload size in bytes
//   bits 15-8:  type char ('E' = 0x45 for evdev)
//   bits  7-0:  command number

fn ioc(dir: u2, typ: u8, nr: u32, size: u14) u32 {
    return @as(u32, dir) << 30 | @as(u32, size) << 16 | @as(u32, typ) << 8 | nr;
}

/// `EVIOCGBIT(ev_type, len)` — get the bitmask of supported codes for a
/// given event type. We use this with `EV_KEY` to check which buttons a
/// device has.
fn eviocgbit(ev: u8, len: u14) u32 {
    return ioc(2, 'E', 0x20 + @as(u32, ev), len);
}

/// `EVIOCGABS(axis)` — get the `AbsInfo` calibration data for one axis.
fn eviocgabs(abs: u8) u32 {
    return ioc(2, 'E', 0x40 + @as(u32, abs), @sizeOf(AbsInfo));
}

// ── inotify constants ───────────────────────────────────────────────────────
//
// We watch /dev/input/ with inotify for hotplug. IN_ATTRIB is needed
// because udev may set permissions after the device file is created.
// These are bitmask flags combined with |, so they stay as constants.

const IN_CREATE: u32 = 0x00000100;
const IN_DELETE: u32 = 0x00000200;
const IN_ATTRIB: u32 = 0x00000004;

// ── per-device bookkeeping ──────────────────────────────────────────────────

const DeviceSlot = struct {
    fd: posix.fd_t,
    id: Id,
    event_number: u16, // the N in /dev/input/eventN, used to deduplicate
    abs_info: [Axis.count]AbsInfo, // calibration data, one per Axis
    sticks_raw: [4]f32 = .{0} ** 4, // pre-deadzone normalized stick values (lx, ly, rx, ry)
    state: State,
};

// ── public API ──────────────────────────────────────────────────────────────

/// Gamepad input context for Linux evdev.
/// NOT thread-safe — all calls (init, poll, deinit) must happen from the same thread.
pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    devices: std.ArrayListUnmanaged(DeviceSlot),
    inotify_fd: posix.fd_t,
    event_buf: std.ArrayListUnmanaged(Event),
    event_pos: usize,
    used_ids: u16, // bitmask — bit N is set when gamepad ID N is in use
    sticky_ids: [common.max_gamepads]?u16, // indexed by Id, stores last-known event_number

    /// Set up the gamepad subsystem: start watching /dev/input for hotplug
    /// and scan for already-connected gamepads.
    pub fn init(io: std.Io, allocator: std.mem.Allocator, options: Options) !@This() {
        const inotify_fd = try inotify_init();
        errdefer _ = linux.close(inotify_fd);

        // If /dev/input doesn't exist (container, etc.) we just won't get
        // hotplug notifications. That's fine — gamepads can still be found
        // in the initial scan if they're already present.
        inotify_add_watch(inotify_fd, "/dev/input") catch {};

        var self = @This(){
            .io = io,
            .allocator = allocator,
            .options = options,
            .devices = .empty,
            .inotify_fd = inotify_fd,
            .event_buf = .empty,
            .event_pos = 0,
            .used_ids = 0,
            .sticky_ids = [_]?u16{null} ** common.max_gamepads,
        };

        self.scan_devices();

        return self;
    }

    /// Close all device file descriptors and the inotify watcher.
    pub fn deinit(self: *@This()) void {
        for (self.devices.items) |dev| _ = linux.close(dev.fd);
        self.devices.deinit(self.allocator);
        self.event_buf.deinit(self.allocator);
        _ = linux.close(self.inotify_fd);
        self.* = undefined;
    }

    /// Return the next pending event, or null if there are none.
    ///
    /// Call this in a loop each frame:
    ///
    ///     while (ctx.poll()) |event| { ... }
    ///
    /// The first call does a non-blocking `poll()` syscall on all device
    /// file descriptors. Subsequent calls drain the buffer without any
    /// additional syscalls.
    pub fn poll(self: *@This()) ?Event {
        // Drain buffered events first.
        if (self.event_pos < self.event_buf.items.len) {
            defer self.event_pos += 1;
            return self.event_buf.items[self.event_pos];
        }

        // Buffer empty — do a new poll cycle.
        self.event_buf.clearRetainingCapacity();
        self.event_pos = 0;
        self.poll_fds();

        if (self.event_pos < self.event_buf.items.len) {
            defer self.event_pos += 1;
            return self.event_buf.items[self.event_pos];
        }
        return null;
    }

    /// Look up a connected gamepad by ID. Returns its current button/axis
    /// state, or null if no gamepad with that ID is connected.
    pub fn get(self: *const @This(), id: Id) ?*const State {
        for (self.devices.items) |*dev| {
            if (dev.id == id) return &dev.state;
        }
        return null;
    }

    // ── internal: polling ───────────────────────────────────────────────

    /// One non-blocking `poll()` over all fds: the inotify watcher (for
    /// hotplug) plus every connected gamepad.
    fn poll_fds(self: *@This()) void {
        const n_devices = self.devices.items.len;
        const n_fds = n_devices + 1; // +1 for inotify

        var pollfds_buf: [common.max_gamepads + 1]linux.pollfd = undefined;
        const pollfds = pollfds_buf[0..n_fds];

        pollfds[0] = .{ .fd = self.inotify_fd, .events = linux.POLL.IN, .revents = 0 };
        for (self.devices.items, 0..) |dev, i| {
            pollfds[1 + i] = .{ .fd = dev.fd, .events = linux.POLL.IN, .revents = 0 };
        }

        // timeout=0 → non-blocking, return immediately.
        const ready = linux.poll(pollfds.ptr, @intCast(n_fds), 0);
        if (@as(isize, @bitCast(ready)) <= 0) return;

        if (pollfds[0].revents & linux.POLL.IN != 0) {
            self.process_inotify();
        }

        // Iterate in reverse so swapRemove during disconnect is safe.
        var i: usize = n_devices;
        while (i > 0) {
            i -= 1;
            const pfd = pollfds[1 + i];

            if (pfd.revents & (linux.POLL.ERR | linux.POLL.HUP) != 0) {
                self.remove_device(i);
                continue;
            }
            if (pfd.revents & linux.POLL.IN != 0) {
                self.read_device(i);
            }
        }
    }

    // ── internal: hotplug via inotify ────────────────────────────────────

    /// Drain all pending inotify events. When a new `eventN` file appears
    /// in /dev/input we try to open it and check if it's a gamepad.
    fn process_inotify(self: *@This()) void {
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;

        while (true) {
            const n = linux.read(self.inotify_fd, &buf, buf.len);
            const bytes_read: isize = @bitCast(n);
            if (bytes_read <= 0) break;

            var offset: usize = 0;
            while (offset + @sizeOf(linux.inotify_event) <= @as(usize, @intCast(bytes_read))) {
                const event: *const linux.inotify_event = @ptrCast(@alignCast(buf[offset..].ptr));
                offset += @sizeOf(linux.inotify_event) + event.len;

                const name = event.getName() orelse continue;

                if (event.mask & (IN_CREATE | IN_ATTRIB) != 0) {
                    if (parse_event_number(name)) |num| {
                        if (!self.has_event_number(num)) {
                            self.try_open_device(num);
                        }
                    }
                }
            }
        }
    }

    // ── internal: reading events from a gamepad ─────────────────────────

    /// Drain all pending `input_event` structs from one gamepad's fd.
    fn read_device(self: *@This(), idx: usize) void {
        const dev = &self.devices.items[idx];
        var events: [64]InputEvent = undefined;

        while (true) {
            const bytes = posix.read(dev.fd, std.mem.sliceAsBytes(&events)) catch |err| switch (err) {
                error.WouldBlock => break,
                // Any other error (including ENODEV → Unexpected) means disconnect.
                else => {
                    self.remove_device(idx);
                    break;
                },
            };

            if (bytes == 0) break;

            const count = bytes / @sizeOf(InputEvent);
            for (events[0..count]) |ev| {
                const ev_type: EvType = @enumFromInt(ev.type);
                switch (ev_type) {
                    .key => self.process_button(dev, ev.code, ev.value),
                    .abs => self.process_axis(dev, ev.code, ev.value),
                    _ => {},
                }
            }
        }
    }

    // ── internal: translating evdev events into our API ─────────────────

    fn process_button(self: *@This(), dev: *DeviceSlot, code: u16, value: i32) void {
        const ev_btn: EvButton = @enumFromInt(code);

        // Some controllers report triggers as digital buttons (BTN_TL2 /
        // BTN_TR2) instead of analog axes. Convert these to axis events
        // so triggers always appear as axis_moved regardless of hardware.
        switch (ev_btn) {
            .tl2 => return self.set_trigger(dev, .left_trigger, value != 0),
            .tr2 => return self.set_trigger(dev, .right_trigger, value != 0),
            else => {},
        }

        const btn = map_button(ev_btn) orelse return;
        const pressed = value != 0;
        const idx = @intFromEnum(btn);

        // Only emit when state actually changes.
        if (dev.state.buttons[idx] == pressed) return;
        dev.state.buttons[idx] = pressed;

        self.emit(if (pressed)
            .{ .button_pressed = .{ .id = dev.id, .button = btn } }
        else
            .{ .button_released = .{ .id = dev.id, .button = btn } });
    }

    /// Convert a digital trigger button into an axis event (0.0 or 1.0).
    fn set_trigger(self: *@This(), dev: *DeviceSlot, axis: Axis, pressed: bool) void {
        const value: f32 = if (pressed) 1.0 else 0.0;
        const idx = @intFromEnum(axis);
        if (dev.state.axes[idx] != value) {
            dev.state.axes[idx] = value;
            self.emit(.{ .axis_moved = .{ .id = dev.id, .axis = axis, .value = value } });
        }
    }

    fn process_axis(self: *@This(), dev: *DeviceSlot, code: u16, raw: i32) void {
        const ev_axis: EvAxis = @enumFromInt(code);

        // Some controllers report the D-pad as a "hat" axis rather than
        // individual buttons. We convert those to button events.
        switch (ev_axis) {
            .hat0x, .hat0y => {
                self.process_dpad_axis(dev, ev_axis, raw);
                return;
            },
            else => {},
        }

        const mapping = map_axis(ev_axis) orelse return;
        const info = dev.abs_info[@intFromEnum(mapping.axis)];

        if (mapping.is_trigger) {
            const value = common.apply_trigger_deadzone(
                normalize_trigger(raw, info),
                self.options.deadzone,
            );
            const idx = @intFromEnum(mapping.axis);
            if (dev.state.axes[idx] != value) {
                dev.state.axes[idx] = value;
                self.emit(.{ .axis_moved = .{ .id = dev.id, .axis = mapping.axis, .value = value } });
            }
        } else {
            // Stick axis — update pre-deadzone value and recompute the
            // radial deadzone for this stick pair. Either axis of the
            // pair may change when the other moves (a radial deadzone
            // treats X/Y as a 2D vector).
            const idx = @intFromEnum(mapping.axis);
            dev.sticks_raw[idx] = normalize_stick(raw, info);

            const x_idx = (idx / 2) * 2; // round down to even: 0 or 2
            const y_idx = x_idx + 1;
            const dz = common.apply_radial_deadzone(
                dev.sticks_raw[x_idx],
                dev.sticks_raw[y_idx],
                self.options.deadzone,
            );

            if (dev.state.axes[x_idx] != dz[0]) {
                dev.state.axes[x_idx] = dz[0];
                self.emit(.{ .axis_moved = .{
                    .id = dev.id,
                    .axis = @enumFromInt(x_idx),
                    .value = dz[0],
                } });
            }
            if (dev.state.axes[y_idx] != dz[1]) {
                dev.state.axes[y_idx] = dz[1];
                self.emit(.{ .axis_moved = .{
                    .id = dev.id,
                    .axis = @enumFromInt(y_idx),
                    .value = dz[1],
                } });
            }
        }
    }

    /// Convert D-pad hat axis to button events.
    /// hat0x: -1 = left,  0 = center, 1 = right
    /// hat0y: -1 = up,    0 = center, 1 = down
    fn process_dpad_axis(self: *@This(), dev: *DeviceSlot, ax: EvAxis, value: i32) void {
        switch (ax) {
            .hat0x => {
                self.set_button(dev, .dpad_left, value < 0);
                self.set_button(dev, .dpad_right, value > 0);
            },
            .hat0y => {
                self.set_button(dev, .dpad_up, value < 0);
                self.set_button(dev, .dpad_down, value > 0);
            },
            else => {},
        }
    }

    fn set_button(self: *@This(), dev: *DeviceSlot, btn: Button, pressed: bool) void {
        const idx = @intFromEnum(btn);
        if (dev.state.buttons[idx] == pressed) return;
        dev.state.buttons[idx] = pressed;

        self.emit(if (pressed)
            .{ .button_pressed = .{ .id = dev.id, .button = btn } }
        else
            .{ .button_released = .{ .id = dev.id, .button = btn } });
    }

    /// Append an event to the buffer. OOM is silently ignored — dropping
    /// an event is better than crashing, and in practice the buffer is
    /// small and rarely reallocates.
    fn emit(self: *@This(), event: Event) void {
        self.event_buf.append(self.allocator, event) catch {
            log.warn("Event dropped: out of memory", .{});
        };
    }

    // ── internal: device management ─────────────────────────────────────

    /// Walk /dev/input/ and probe every eventN file. Non-gamepad devices
    /// are closed immediately.
    fn scan_devices(self: *@This()) void {
        var dir = std.Io.Dir.openDirAbsolute(self.io, "/dev/input", .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (parse_event_number(entry.name)) |num| {
                self.try_open_device(num);
            }
        }
    }

    /// Try to open /dev/input/eventN. If it's a gamepad, register it.
    fn try_open_device(self: *@This(), event_number: u16) void {
        if (self.devices.items.len >= common.max_gamepads) return;

        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/dev/input/event{d}", .{event_number}) catch return;

        const fd = posix.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0) catch return;

        // Ask the kernel which buttons this device supports. If it doesn't
        // have BTN_SOUTH (0x130, a.k.a. BTN_GAMEPAD), it's not a gamepad.
        if (!is_gamepad(fd)) {
            _ = linux.close(fd);
            return;
        }

        // If this event_number was previously assigned an ID, reclaim it
        // so the same controller keeps its player slot after reconnect.
        const id = self.reclaim_sticky_id(event_number) orelse self.allocate_id() orelse {
            _ = linux.close(fd);
            return;
        };

        // Read calibration data so we can normalize each axis later.
        // Order matches the Axis enum: left_stick_x/y, right_stick_x/y,
        // left_trigger, right_trigger.
        const axis_codes = [_]EvAxis{ .x, .y, .rx, .ry, .z, .rz };
        var abs_info: [Axis.count]AbsInfo = undefined;
        for (axis_codes, 0..) |ax, i| {
            abs_info[i] = query_abs_info(fd, @intCast(@intFromEnum(ax)));
        }

        self.devices.append(self.allocator, .{
            .fd = fd,
            .id = id,
            .event_number = event_number,
            .abs_info = abs_info,
            .state = .{},
        }) catch {
            self.free_id(id);
            _ = linux.close(fd);
            return;
        };

        self.emit(.{ .connected = id });
    }

    fn remove_device(self: *@This(), idx: usize) void {
        const dev = self.devices.items[idx];
        _ = linux.close(dev.fd);
        // Remember which event_number this ID was using, so the same
        // controller gets the same ID when it reconnects.
        self.sticky_ids[dev.id] = dev.event_number;
        self.free_id(dev.id);
        self.emit(.{ .disconnected = dev.id });
        _ = self.devices.swapRemove(idx);
    }

    fn has_event_number(self: *const @This(), num: u16) bool {
        for (self.devices.items) |dev| {
            if (dev.event_number == num) return true;
        }
        return false;
    }

    // ── internal: ID pool ───────────────────────────────────────────────
    //
    // IDs are recycled from a 16-bit pool. When a gamepad disconnects,
    // its event_number → ID mapping is remembered in sticky_ids. If the
    // same event_number reappears (e.g. controller reconnects after
    // battery swap), it reclaims the same ID so player assignment is
    // stable. A fresh ID is allocated only for genuinely new devices.

    /// Check if a previously-disconnected ID was associated with this
    /// event_number. If so, reclaim it (mark used, clear sticky entry).
    fn reclaim_sticky_id(self: *@This(), event_number: u16) ?Id {
        for (&self.sticky_ids, 0..) |*entry, i| {
            if (entry.* == event_number) {
                const id: Id = @intCast(i);
                entry.* = null;
                self.used_ids |= @as(u16, 1) << id;
                return id;
            }
        }
        return null;
    }

    fn allocate_id(self: *@This()) ?Id {
        var i: u5 = 0;
        while (i < common.max_gamepads) : (i += 1) {
            const bit: u4 = @truncate(i);
            if (self.used_ids & (@as(u16, 1) << bit) == 0) {
                self.used_ids |= @as(u16, 1) << bit;
                return bit;
            }
        }
        return null;
    }

    fn free_id(self: *@This(), id: Id) void {
        self.used_ids &= ~(@as(u16, 1) << id);
    }
};

// ── device probing (free functions) ─────────────────────────────────────────

/// Check whether an fd points to a gamepad by querying its supported
/// button bitmask and looking for `EvButton.south` (BTN_GAMEPAD).
fn is_gamepad(fd: posix.fd_t) bool {
    const key_bits_len = (EvButton.key_max / 8) + 1;
    var key_bits: [key_bits_len]u8 = .{0} ** key_bits_len;

    const ret: isize = @bitCast(linux.ioctl(
        @intCast(fd),
        eviocgbit(@intFromEnum(EvType.key), @intCast(key_bits_len)),
        @intFromPtr(&key_bits),
    ));
    if (ret < 0) return false;

    return test_bit(@intFromEnum(EvButton.south), &key_bits);
}

/// Read calibration data (min/max range) for one axis via ioctl.
fn query_abs_info(fd: posix.fd_t, abs_code: u8) AbsInfo {
    var info = std.mem.zeroes(AbsInfo);
    const ret: isize = @bitCast(linux.ioctl(@intCast(fd), eviocgabs(abs_code), @intFromPtr(&info)));
    if (ret < 0) {
        log.warn("ioctl EVIOCGABS failed for axis 0x{x}", .{abs_code});
    }
    return info;
}

/// Test whether a specific bit is set in a byte array.
fn test_bit(bit: u16, array: []const u8) bool {
    const byte_idx = bit / 8;
    const bit_idx: u3 = @truncate(bit % 8);
    if (byte_idx >= array.len) return false;
    return (array[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
}

// ── inotify helpers ─────────────────────────────────────────────────────────
//
// No std.posix wrapper exists for inotify, so we call the raw syscalls
// and convert errors manually.

fn inotify_init() !posix.fd_t {
    const flags: u32 = @bitCast(linux.O{ .NONBLOCK = true, .CLOEXEC = true });
    const ret = linux.inotify_init1(flags);
    const signed: isize = @bitCast(ret);
    if (signed < 0) {
        return posix.unexpectedErrno(@enumFromInt(@as(u16, @intCast(-signed))));
    }
    return @intCast(signed);
}

fn inotify_add_watch(fd: posix.fd_t, path: [*:0]const u8) !void {
    const ret = linux.inotify_add_watch(fd, path, IN_CREATE | IN_ATTRIB | IN_DELETE);
    const signed: isize = @bitCast(ret);
    if (signed < 0) {
        return posix.unexpectedErrno(@enumFromInt(@as(u16, @intCast(-signed))));
    }
}

// ── mapping tables ──────────────────────────────────────────────────────────
//
// Translate Linux-specific evdev codes into platform-independent enums.

fn map_button(code: EvButton) ?Button {
    return switch (code) {
        .south => .south,
        .east => .east,
        .north => .north,
        .west => .west,
        .tl => .left_bumper,
        .tr => .right_bumper,
        .tl2, .tr2 => null, // handled as axis events in process_button
        .select => .back,
        .start => .start,
        .mode => .guide,
        .thumbl => .left_stick,
        .thumbr => .right_stick,
        .dpad_up => .dpad_up,
        .dpad_down => .dpad_down,
        .dpad_left => .dpad_left,
        .dpad_right => .dpad_right,
        _ => null,
    };
}

const AxisMapping = struct {
    axis: Axis,
    is_trigger: bool,
};

fn map_axis(code: EvAxis) ?AxisMapping {
    return switch (code) {
        .x => .{ .axis = .left_stick_x, .is_trigger = false },
        .y => .{ .axis = .left_stick_y, .is_trigger = false },
        .rx => .{ .axis = .right_stick_x, .is_trigger = false },
        .ry => .{ .axis = .right_stick_y, .is_trigger = false },
        .z => .{ .axis = .left_trigger, .is_trigger = true },
        .rz => .{ .axis = .right_trigger, .is_trigger = true },
        .hat0x, .hat0y, _ => null,
    };
}

// ── axis normalization ──────────────────────────────────────────────────────
//
// Sticks:   raw [min, max] → [-1.0, 1.0]
// Triggers: raw [min, max] → [ 0.0, 1.0]

fn normalize_stick(raw: i32, info: AbsInfo) f32 {
    if (info.maximum == info.minimum) return 0;
    const range: f32 = @floatFromInt(@as(i64, info.maximum) - @as(i64, info.minimum));
    const centered: f32 = @floatFromInt(@as(i64, raw) - @as(i64, info.minimum));
    return std.math.clamp((centered / range) * 2.0 - 1.0, -1.0, 1.0);
}

fn normalize_trigger(raw: i32, info: AbsInfo) f32 {
    if (info.maximum == info.minimum) return 0;
    const range: f32 = @floatFromInt(@as(i64, info.maximum) - @as(i64, info.minimum));
    const value: f32 = @floatFromInt(@as(i64, raw) - @as(i64, info.minimum));
    return std.math.clamp(value / range, 0.0, 1.0);
}

// ── utility ─────────────────────────────────────────────────────────────────

/// Extract the number from an event device name: "event5" → 5.
fn parse_event_number(name: []const u8) ?u16 {
    const prefix = "event";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const digits = name[prefix.len..];
    if (digits.len == 0) return null;
    return std.fmt.parseUnsigned(u16, digits, 10) catch null;
}

// ── tests ───────────────────────────────────────────────────────────────────

test "parse_event_number" {
    const testing = std.testing;
    try testing.expectEqual(@as(?u16, 0), parse_event_number("event0"));
    try testing.expectEqual(@as(?u16, 5), parse_event_number("event5"));
    try testing.expectEqual(@as(?u16, 123), parse_event_number("event123"));
    try testing.expectEqual(@as(?u16, null), parse_event_number("mouse0"));
    try testing.expectEqual(@as(?u16, null), parse_event_number("event"));
    try testing.expectEqual(@as(?u16, null), parse_event_number("eventX"));
}

test "normalize_stick" {
    const testing = std.testing;
    const info = AbsInfo{
        .value = 0,
        .minimum = -32768,
        .maximum = 32767,
        .fuzz = 0,
        .flat = 128,
        .resolution = 0,
    };
    try testing.expectApproxEqAbs(@as(f32, 0.0), normalize_stick(0, info), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), normalize_stick(32767, info), 0.001);
    try testing.expectApproxEqAbs(@as(f32, -1.0), normalize_stick(-32768, info), 0.001);
}

test "normalize_trigger" {
    const testing = std.testing;
    const info = AbsInfo{
        .value = 0,
        .minimum = 0,
        .maximum = 255,
        .fuzz = 0,
        .flat = 0,
        .resolution = 0,
    };
    try testing.expectApproxEqAbs(@as(f32, 0.0), normalize_trigger(0, info), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), normalize_trigger(255, info), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), normalize_trigger(127, info), 0.01);
}
