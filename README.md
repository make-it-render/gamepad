# mir-gamepad

Cross-platform gamepad input library for Zig. No system dependencies — pure
syscalls for easy cross-compilation.

Provides a unified API over platform-specific backends using comptime dispatch.

**Supported platforms:** Linux (evdev), Windows (XInput)

## Features

- Automatic gamepad discovery with connect/disconnect events
- Event-based polling and direct state queries
- Positional button naming (south/east/west/north) — works for any controller
- Radial stick deadzone and trigger deadzone with configurable threshold
- Up to 16 simultaneous gamepads

## Usage

### Install

```sh
zig fetch --save git+https://github.com/make-it-render/mir-gamepad
```

### build.zig

```zig
const gamepad_dep = b.dependency("mir_gamepad", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("mir_gamepad", gamepad_dep.module("mir_gamepad"));
```

### Example

```zig
const std = @import("std");
const gamepad = @import("mir_gamepad");

var ctx = try gamepad.Context.init(allocator, .{});
defer ctx.deinit();

while (true) {
    while (ctx.poll()) |event| {
        switch (event) {
            .connected => |id| std.debug.print("[pad {d}] connected\n", .{id}),
            .disconnected => |id| std.debug.print("[pad {d}] disconnected\n", .{id}),
            .button_pressed => |e| std.debug.print("[pad {d}] pressed {s}\n", .{ e.id, @tagName(e.button) }),
            .button_released => |e| std.debug.print("[pad {d}] released {s}\n", .{ e.id, @tagName(e.button) }),
            .axis_moved => |e| std.debug.print("[pad {d}] {s} = {d:.3}\n", .{ e.id, @tagName(e.axis), e.value }),
        }
    }

    std.Thread.sleep(16 * std.time.ns_per_ms); // ~60 Hz
}
```

For a complete working example, see [src/main.zig](src/main.zig).

### Direct state queries

```zig
if (ctx.get(0)) |pad| {
    const x = pad.axis(.left_stick_x);   // f32 -1..1
    const lt = pad.axis(.left_trigger);  // f32  0..1
    const jump = pad.button(.south);     // bool
}
```

## API

### Context options

```zig
var ctx = try gamepad.Context.init(allocator, .{
    .deadzone = 0.15,  // analog stick deadzone threshold (0.0–1.0, default: 0.2)
});
```

### Events

Events are delivered via `ctx.poll()`, which returns the next pending event or `null`.

| Event | Payload | Description |
|-------|---------|-------------|
| `.connected` | `Id` | Gamepad connected |
| `.disconnected` | `Id` | Gamepad disconnected |
| `.button_pressed` | `id`, `button` | Button pressed |
| `.button_released` | `id`, `button` | Button released |
| `.axis_moved` | `id`, `axis`, `value` | Analog axis changed |

Events are emitted only when state actually changes: you will never get two consecutive `button_pressed` events for the same button without a `button_released` in between.

### Buttons

Positional naming avoids confusion between vendors:

| Position | Xbox | PlayStation | Nintendo |
|----------|------|-------------|----------|
| `south` | A | Cross | B |
| `east` | B | Circle | A |
| `west` | X | Square | Y |
| `north` | Y | Triangle | X |

Other buttons: `left_bumper`, `right_bumper`, `back`, `start`, `guide`,
`left_stick`, `right_stick`, `dpad_up`, `dpad_down`, `dpad_left`, `dpad_right`.

### Axes

| Axis | Range |
|------|-------|
| `left_stick_x`, `left_stick_y` | -1.0 .. 1.0 |
| `right_stick_x`, `right_stick_y` | -1.0 .. 1.0 |
| `left_trigger`, `right_trigger` | 0.0 .. 1.0 |

### State

`State` provides a snapshot of a gamepad's current button and axis values, useful for direct queries when you don't need to react to every individual event.

```zig
if (ctx.get(0)) |pad| {
    const pressed = pad.button(.south);     // bool
    const value = pad.axis(.left_stick_x);  // f32
}
```

## Building

```sh
zig build          # build library + demo
zig build run      # run the demo app
zig build test     # run tests
zig build docs     # generate documentation
```

### Cross-compilation

```sh
zig build -Dtarget=x86_64-linux
zig build -Dtarget=aarch64-linux
zig build -Dtarget=x86_64-windows
```

## Steam compatibility

Steam-managed controllers (PlayStation, Nintendo, Steam Controller, Steam Deck)
work out of the box — no Steam SDK needed. Steam's built-in gamepad emulation
creates virtual OS-level devices (evdev on Linux, XInput on Windows) that the
existing backends pick up automatically.

## License

MIT

Copyright (c) Diogo Souza da Silva
