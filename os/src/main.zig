const build_options = @import("build_options");
const entry = @import("entry.zig");
const fb = @import("console/fb.zig");
const printf = fb.printf;
const halt = @import("halt.zig").halt;

usingnamespace @import("hacks.zig");

// From daintree_mmu_start.
export fn daintree_main(entry_data: *entry.EntryData) void {
    HACK_uartAt(@intToPtr(*volatile u8, entry_data.uart_base), .{ "daintree_main ", @ptrToInt(entry_data), "\r\n" });
    uart_global = @intToPtr(*volatile u8, entry_data.uart_base);
    HACK_uart(.{ "trying thru uart_global @ ", @ptrToInt(&uart_global), "\r\n" });

    var fb_vert: u32 = @truncate(u32, (entry_data.verthoriz >> 32) & 0xffffffff);
    var fb_horiz: u32 = @truncate(u32, entry_data.verthoriz & 0xffffffff);

    HACK_uart(.{ "fb_vert ", fb_vert, " fb_horiz ", fb_horiz, "\r\n" });

    fb.init(entry_data.fb, fb_vert, fb_horiz);

    HACK_uart(.{"init success\r\n"});

    printf("\x1b\x0adaintree \x1b\x07{s} on {s}\n", .{ build_options.version, build_options.board });

    var i: u9 = 0;
    while (i < 256) : (i += 1) {
        if (i == '\n' or i == 0x1b) {
            printf(" ", .{});
        } else {
            printf("{c}", .{@truncate(u8, i)});
        }
        if (i % 32 == 0) {
            printf("\n", .{});
        }
    }

    halt();
}
