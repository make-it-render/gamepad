# mir-gamepad

Cross-platform gamepad input library for Zig. No system dependencies — pure
syscalls for easy cross-compilation.

## Backends

| Platform | Backend | Status |
|----------|---------|--------|
| Linux | evdev (raw syscalls, no libudev) | Done |
| Windows | XInput (dynamic `xinput1_4.dll`) | Planned |
| Steam | Steam Input (runtime dlopen) | Planned |

## Usage

Add as a dependency in your `build.zig.zon`:

```zon
.gamepad = .{ .path = "../mir-gamepad" },
```

Import in `build.zig`:

```zig
const gamepad_dep = b.dependency("gamepad", .{ .target = target, .optimize = optimize });
my_module.addImport("mir_gamepad", gamepad_dep.module("mir_gamepad"));
```

### Event polling

```zig
const gamepad = @import("mir_gamepad");

var ctx = try gamepad.Context.init(allocator, .{});
defer ctx.deinit();

while (ctx.poll()) |event| {
    switch (event) {
        .connected       => |id| { ... },
        .disconnected    => |id| { ... },
        .button_pressed  => |e| { // e.id, e.button },
        .button_released => |e| { ... },
        .axis_moved      => |e| { // e.id, e.axis, e.value },
    }
}
```

### Direct state queries

```zig
if (ctx.get(0)) |pad| {
    const x = pad.axis(.left_stick_x);   // f32 -1..1
    const lt = pad.axis(.left_trigger);  // f32  0..1
    const jump = pad.button(.south);     // bool
}
```

## Buttons

Positional naming avoids confusion between vendors:

| Position | Xbox | PlayStation | Nintendo |
|----------|------|-------------|----------|
| `south` | A | Cross | B |
| `east` | B | Circle | A |
| `west` | X | Square | Y |
| `north` | Y | Triangle | X |

Other buttons: `left_bumper`, `right_bumper`, `back`, `start`, `guide`,
`left_stick`, `right_stick`, `dpad_up`, `dpad_down`, `dpad_left`, `dpad_right`.

## Axes

| Axis | Range |
|------|-------|
| `left_stick_x`, `left_stick_y` | -1.0 .. 1.0 |
| `right_stick_x`, `right_stick_y` | -1.0 .. 1.0 |
| `left_trigger`, `right_trigger` | 0.0 .. 1.0 |

## Options

```zig
var ctx = try gamepad.Context.init(allocator, .{
    .deadzone = 0.15,  // default: 0.2
});
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
```

## License

MIT
