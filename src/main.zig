//! Demo application — prints every gamepad event to stderr.
//! Run with: zig build run

const std = @import("std");
const gamepad = @import("gamepad");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var ctx = try gamepad.Context.init(io, allocator, .{});
    defer ctx.deinit();

    std.debug.print("gamepad demo — press Ctrl+C to quit\n", .{});
    std.debug.print("Listening for gamepad events...\n\n", .{});

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

        // Poll at ~60 Hz to avoid busy-waiting.
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(16), .awake);
    }
}
