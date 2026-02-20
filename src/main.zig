//! Demo application — prints every gamepad event to stderr.
//! Run with: zig build run

const std = @import("std");
const gamepad = @import("mir_gamepad");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var ctx = try gamepad.Context.init(gpa.allocator(), .{});
    defer ctx.deinit();

    std.debug.print("mir-gamepad demo — press Ctrl+C to quit\n", .{});
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
        std.Thread.sleep(16 * std.time.ns_per_ms);
    }
}
