# mir-gamepad — Standalone Gamepad Library for Zig

## Overview

A standalone, cross-compilable Zig gamepad library with three backends:
Linux (evdev), Windows (XInput), and Steam Input. No system dependencies —
everything is done via raw syscalls and dynamic library loading.

Integrates with `make-it-render` as a peer dependency (like `anywindow`,
`text`, `image`) but can be used independently by any Zig project.

## Public API

```zig
const gamepad = @import("mir_gamepad");

var gp = try gamepad.Context.init(allocator, .{});
defer gp.deinit();

// Per-frame polling — returns events for all connected gamepads:
while (gp.poll()) |event| {
    switch (event) {
        .connected    => |id| { ... },
        .disconnected => |id| { ... },
        .button_pressed  => |e| { // e.id, e.button },
        .button_released => |e| { ... },
        .axis_moved      => |e| { // e.id, e.axis, e.value },
    }
}

// Direct state queries:
if (gp.get(0)) |pad| {
    const lx = pad.axis(.left_stick_x); // f32 -1..1
    const lt = pad.axis(.left_trigger);  // f32  0..1
    const a  = pad.button(.south);       // bool
}
```

## Types

### `Id`

`u8` — gamepad slot index (0–15).

### `Button`

```zig
const Button = enum {
    south,        // Xbox A, PS Cross
    east,         // Xbox B, PS Circle
    west,         // Xbox X, PS Square
    north,        // Xbox Y, PS Triangle
    left_bumper,  // LB / L1
    right_bumper, // RB / R1
    back,         // Select / Back / Share
    start,        // Start / Menu / Options
    guide,        // Home / Xbox / PS
    left_stick,   // L3
    right_stick,  // R3
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
};
```

### `Axis`

```zig
const Axis = enum {
    left_stick_x,   // -1..1
    left_stick_y,   // -1..1
    right_stick_x,  // -1..1
    right_stick_y,  // -1..1
    left_trigger,   //  0..1
    right_trigger,  //  0..1
};
```

### `Event`

```zig
const Event = union(enum) {
    connected: Id,
    disconnected: Id,
    button_pressed:  struct { id: Id, button: Button },
    button_released: struct { id: Id, button: Button },
    axis_moved:      struct { id: Id, axis: Axis, value: f32 },
};
```

## Module Structure

```
mir-gamepad/
├── build.zig
├── build.zig.zon
├── PLAN.md
└── src/
    ├── root.zig          # Public API re-exports
    ├── common.zig        # Button, Axis, Event, Id, State
    ├── evdev.zig         # Linux backend (raw syscalls, no libc/libudev)
    ├── xinput.zig         # Windows backend (LoadLibraryW + GetProcAddress)
    └── steam.zig         # Steam Input backend (dlopen/LoadLibrary)
```

## Backend Details

### 1. Linux — evdev (no system dependencies)

All interaction via raw syscalls through Zig's `std.posix` / `std.os.linux`:

- **Device discovery**: Iterate `/dev/input/event*`, open with `O_RDONLY | O_NONBLOCK`
- **Device identification**: `ioctl(fd, EVIOCGBIT(EV_KEY, ...), &bits)` — check for `BTN_GAMEPAD` (0x130)
- **Axis calibration**: `ioctl(fd, EVIOCGABS(axis), &absinfo)` — get min/max/flat for normalization
- **Event reading**: `read(fd, &input_event)` — 24 bytes per event on 64-bit
- **Hotplug connect**: `inotify_init1()` + `inotify_add_watch("/dev/input", IN_CREATE | IN_ATTRIB)`
- **Hotplug disconnect**: `poll()` returns `POLLHUP` / `POLLERR`, or `read()` returns `ENODEV`
- **Polling**: Single `poll()` call over all gamepad fds + inotify fd

#### ioctl encoding (computed at comptime)

```
_IOC(dir, type, nr, size) = (dir << 30) | (size << 16) | (type << 8) | nr
type = 'E' (0x45) for evdev
```

Key ioctls:
- `EVIOCGNAME(len)` = `_IOC(2, 'E', 0x06, len)` — device name
- `EVIOCGID` = `_IOC(2, 'E', 0x02, 8)` — vendor/product ID
- `EVIOCGBIT(ev, len)` = `_IOC(2, 'E', 0x20+ev, len)` — capability bits
- `EVIOCGABS(abs)` = `_IOC(2, 'E', 0x40+abs, 24)` — axis info

#### evdev event codes

Buttons:
- `BTN_SOUTH` (0x130), `BTN_EAST` (0x131), `BTN_NORTH` (0x133), `BTN_WEST` (0x134)
- `BTN_TL` (0x136), `BTN_TR` (0x137), `BTN_TL2` (0x138), `BTN_TR2` (0x139)
- `BTN_SELECT` (0x13a), `BTN_START` (0x13b), `BTN_MODE` (0x13c)
- `BTN_THUMBL` (0x13d), `BTN_THUMBR` (0x13e)
- `BTN_DPAD_UP` (0x220), `BTN_DPAD_DOWN` (0x221), `BTN_DPAD_LEFT` (0x222), `BTN_DPAD_RIGHT` (0x223)

Axes:
- `ABS_X` (0x00), `ABS_Y` (0x01) — left stick
- `ABS_RX` (0x03), `ABS_RY` (0x04) — right stick
- `ABS_Z` (0x02), `ABS_RZ` (0x05) — triggers
- `ABS_HAT0X` (0x10), `ABS_HAT0Y` (0x11) — D-pad (as axis)

#### Axis normalization

Sticks: `(value - center) / half_range` → `f32` in `[-1.0, 1.0]`
Triggers: `(value - min) / range` → `f32` in `[0.0, 1.0]`

#### Deadzone

Scaled radial deadzone for sticks (treats X/Y as 2D vector):
```
magnitude = sqrt(x*x + y*y)
if magnitude < deadzone: return (0, 0)
scale = ((magnitude - deadzone) / (1.0 - deadzone)) / magnitude
return (x * scale, y * scale)
```

Default deadzone: 0.2 (configurable).

### 2. Windows — XInput (no system dependencies)

Dynamic load `xinput1_4.dll` at runtime via `std.os.windows.kernel32`:

- `LoadLibraryW("xinput1_4.dll")` — falls back to `xinput9_1_0.dll`
- `GetProcAddress` for `XInputGetState`, `XInputSetState`, `XInputGetCapabilities`
- **4 controller slots** (XInput limit)
- **Hotplug**: Poll disconnected slots every ~2 seconds (probing empty slots costs ~3ms each)
- **Hotplug disconnect**: `XInputGetState` returns `ERROR_DEVICE_NOT_CONNECTED` (1167)

#### XINPUT_GAMEPAD layout (12 bytes)

```
wButtons:      u16  — button bitmask
bLeftTrigger:  u8   — 0–255
bRightTrigger: u8   — 0–255
sThumbLX:      i16  — -32768..32767
sThumbLY:      i16  — -32768..32767
sThumbRX:      i16  — -32768..32767
sThumbRY:      i16  — -32768..32767
```

#### Button constants

```
DPAD_UP=0x0001, DPAD_DOWN=0x0002, DPAD_LEFT=0x0004, DPAD_RIGHT=0x0008
START=0x0010, BACK=0x0020, LEFT_THUMB=0x0040, RIGHT_THUMB=0x0080
LEFT_SHOULDER=0x0100, RIGHT_SHOULDER=0x0200
A=0x1000, B=0x2000, X=0x4000, Y=0x8000
```

### 3. Steam Input (optional, runtime-loaded)

Dynamic load `libsteam_api.so` (Linux) / `steam_api64.dll` (Windows):

- If load fails or `SteamAPI_Init()` fails → fall back to native backend
- When active, **replaces** native backend (Steam hooks raw input APIs)
- Uses flat C API from `steam_api_flat.h` — all functions declared as `extern`
- Action-based model mapped to raw button/axis emulation for uniform API
- Supports up to 16 controllers, all controller types Steam recognizes

#### Backend selection (runtime)

```
1. Try Steam Input (dlopen → SteamAPI_Init → ISteamInput::Init)
   → Success: use Steam for ALL gamepads
   → Failure: fall back to step 2

2. Use platform-native backend:
   → Linux: evdev
   → Windows: XInput
```

Steam and native backends are mutually exclusive — never poll both simultaneously.

## Integration with make-it-render

### As a dependency

```zon
# make-it-render/build.zig.zon
.gamepad = .{ .path = "../mir-gamepad" },
```

```zig
// make-it-render/build.zig
const gamepad = b.dependency("gamepad", .{ .target = target, .optimize = optimize });
make_it_render.addImport("gamepad", gamepad.module("mir_gamepad"));
```

### Usage alongside anywindow

```zig
const mir = @import("make_it_render");
const gamepad = @import("gamepad");

var wm = try mir.WindowManager.init(allocator);
var gp = try gamepad.Context.init(allocator, .{});

while (running) {
    // Window events
    while (wm.receive()) |event| { ... }
    // Gamepad events
    while (gp.poll()) |event| { ... }
}
```

The consumer (make-it-render or end-user) is responsible for combining both
event streams. mir-gamepad does NOT depend on anywindow.

## Implementation Order

1. **Common types** (`common.zig`, `root.zig`) — Button, Axis, Event, Id, State
2. **Linux evdev backend** (`evdev.zig`) — full implementation with hotplug
3. **Windows XInput backend** (`xinput.zig`) — full implementation with hotplug
4. **Steam Input backend** (`steam.zig`) — optional overlay
5. **Build system** (`build.zig`) — module, tests, demo executable

## Cross-Compilation

Zero system dependencies on any platform:
- **Linux**: Raw syscalls via `std.os.linux` — no libc, no libudev, no pkg-config
- **Windows**: Dynamic load xinput DLL — no link-time dependency on Windows SDK
- **Steam**: Runtime dlopen — binary works with or without Steam installed

`zig build -Dtarget=x86_64-linux` and `zig build -Dtarget=x86_64-windows`
both work from any host without any system libraries installed.
