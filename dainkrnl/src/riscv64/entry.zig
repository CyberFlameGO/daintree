const std = @import("std");
const build_options = @import("build_options");
const dcommon = @import("../common/dcommon.zig");
const arch = @import("arch.zig");
const hw = @import("../hw.zig");

usingnamespace @import("paging.zig");

fn entryAssert(cond: bool, comptime msg: []const u8) callconv(.Inline) void {
    if (!cond) {
        hw.entry_uart.carefully(.{ msg, "\r\n" });
        while (true) {}
    }
}

/// dainboot passes control here.  MMU is **off**.  We are in S-mode.
pub export fn daintree_mmu_start(entry_data: *dcommon.EntryData) noreturn {
    hw.entry_uart.init(entry_data);

    const daintree_base = arch.loadAddress("__daintree_base");
    const daintree_rodata_base = arch.loadAddress("__daintree_rodata_base");
    const daintree_data_base = arch.loadAddress("__daintree_data_base");
    const daintree_end = arch.loadAddress("__daintree_end");
    const daintree_main = arch.loadAddress("daintree_main");
    const trap_entry = arch.loadAddress("__trap_entry");

    hw.entry_uart.carefully(.{ "__daintree_base: ", daintree_base, "\r\n" });
    hw.entry_uart.carefully(.{ "__daintree_rodata_base: ", daintree_rodata_base, "\r\n" });
    hw.entry_uart.carefully(.{ "__daintree_data_base: ", daintree_data_base, "\r\n" });
    hw.entry_uart.carefully(.{ "__daintree_end: ", daintree_end, "\r\n" });
    hw.entry_uart.carefully(.{ "daintree_main: ", daintree_main, "\r\n" });
    hw.entry_uart.carefully(.{ "__trap_entry: ", trap_entry, "\r\n" });

    var bump = paging.BumpAllocator{ .next = daintree_end };
    PT_L1 = bump.alloc([PAGING.index_size]u64);
    PTS_L2 = bump.alloc([PAGING.index_size]u64);
    PTS_L3_1 = bump.alloc([PAGING.index_size]u64);
    PTS_L3_2 = bump.alloc([PAGING.index_size]u64);
    PTS_L3_3 = bump.alloc([PAGING.index_size]u64);

    std.debug.assert((@ptrToInt(PT_L1) & 0xfff) == 0);

    // XXX: start from 0 to include syscon in mapped range so CI works.
    var it = PAGING.range(1, 0, entry_data.conventional_start + entry_data.conventional_bytes);
    while (it.next()) |r| {
        hw.entry_uart.carefully(.{ "mapping identity: page ", r.page, " address ", r.address, "\r\n" });
        tableSet(PT_L1, r.page, PageTableEntry{
            .rwx = .rwx,
            .u = 0,
            .g = 0,
            .a = 1, // XXX ???
            .d = 1, // XXX ???
            .ppn = @truncate(u44, r.address >> PAGING.page_bits),
        });
    }

    tableSet(PT_L1, 256, .{ .rwx = .non_leaf, .u = 0, .g = 0, .a = 1, .d = 1, .ppn = @truncate(u44, @ptrToInt(PTS_L2) >> PAGING.page_bits) });
    tableSet(PTS_L2, 0, .{ .rwx = .non_leaf, .u = 0, .g = 0, .a = 1, .d = 1, .ppn = @truncate(u44, @ptrToInt(PTS_L3_1) >> PAGING.page_bits) });
    tableSet(PTS_L2, 1, .{ .rwx = .non_leaf, .u = 0, .g = 0, .a = 1, .d = 1, .ppn = @truncate(u44, @ptrToInt(PTS_L3_2) >> PAGING.page_bits) });
    tableSet(PTS_L2, 2, .{ .rwx = .non_leaf, .u = 0, .g = 0, .a = 1, .d = 1, .ppn = @truncate(u44, @ptrToInt(PTS_L3_3) >> PAGING.page_bits) });

    var end: u64 = (daintree_end - daintree_base) >> PAGING.page_bits;
    entryAssert(end <= 512, "end got too big (1)");

    var address = daintree_base;
    var rwx: RWX = .rx;
    var i: u64 = 0;
    hw.entry_uart.carefully(.{ "MAP: text at   ", PAGING.kernelPageAddress(i), "~\r\n" });
    while (i < end) : (i += 1) {
        if (address >= daintree_data_base) {
            if (rwx != .rw) {
                hw.entry_uart.carefully(.{ "MAP: data at   ", PAGING.kernelPageAddress(i), "~\r\n" });
                rwx = .rw;
            }
        } else if (address >= daintree_rodata_base) {
            if (rwx != .ro) {
                hw.entry_uart.carefully(.{ "MAP: rodata at ", PAGING.kernelPageAddress(i), "~\r\n" });
                rwx = .ro;
            }
        }

        tableSet(PTS_L3_1, i, .{ .rwx = rwx, .u = 0, .g = 0, .a = 1, .d = 1, .ppn = @truncate(u44, address >> PAGING.page_bits) });
        address += PAGING.page_size;
    }

    // i = end
    end += 5; // PT_L1 .. PTS_L3_3
    hw.entry_uart.carefully(.{ "MAP: null at   ", PAGING.kernelPageAddress(i), "~\r\n" });
    while (i < end) : (i += 1) {
        tableSet(PTS_L3_1, i, std.mem.zeroes(PageTableEntry));
    }
    end = i + STACK_PAGES;
    hw.entry_uart.carefully(.{ "MAP: stack at  ", PAGING.kernelPageAddress(i), "~\r\n" });
    while (i < end) : (i += 1) {
        tableSet(PTS_L3_1, i, .{ .rwx = .rw, .u = 0, .g = 0, .a = 1, .d = 1, .ppn = @truncate(u44, address >> PAGING.page_bits) });
        address += PAGING.page_size;
    }

    entryAssert(end <= 512, "end got too big (2)");

    hw.entry_uart.carefully(.{ "MAP: UART at   ", PAGING.kernelPageAddress(i), "\r\n" });
    // XXX doesn't look like RV MMU needs any special peripheral/cacheability stuff?
    tableSet(PTS_L3_1, i, .{ .rwx = .rw, .u = 0, .g = 0, .a = 1, .d = 1, .ppn = @truncate(u44, entry_data.uart_base >> 12) });

    // Below is verbatim from arm64 entry. ---
    var entry_address = address - @sizeOf(dcommon.EntryData);
    entry_address &= ~@as(u64, 15);
    var new_entry = @intToPtr(*dcommon.EntryData, entry_address);
    new_entry.* = .{
        .memory_map = entry_data.memory_map,
        .memory_map_size = entry_data.memory_map_size,
        .descriptor_size = entry_data.descriptor_size,
        .dtb_ptr = undefined,
        .dtb_len = entry_data.dtb_len,
        .conventional_start = entry_data.conventional_start,
        .conventional_bytes = entry_data.conventional_bytes,
        .fb = entry_data.fb,
        .fb_vert = entry_data.fb_vert,
        .fb_horiz = entry_data.fb_horiz,
        .uart_base = PAGING.kernelPageAddress(end),
        .uart_width = entry_data.uart_width,
    };

    var new_sp = PAGING.kernelPageAddress(end);
    new_sp -= @sizeOf(dcommon.EntryData);
    new_sp &= ~@as(u64, 15);

    {
        i += 1;
        new_entry.dtb_ptr = @intToPtr([*]const u8, PAGING.kernelPageAddress(i));
        std.mem.copy(u8, @intToPtr([*]u8, address)[0..entry_data.dtb_len], entry_data.dtb_ptr[0..entry_data.dtb_len]);

        // How many pages?
        const dtb_pages = (entry_data.dtb_len + PAGING.page_size - 1) / PAGING.page_size;

        var new_end = end + 1 + dtb_pages; // Skip 1 page since UART is there
        entryAssert(new_end <= 512, "end got too big (3)");

        hw.entry_uart.carefully(.{ "MAP: DTB at    ", PAGING.kernelPageAddress(i), "~\r\n" });
        while (i < new_end) : (i += 1) {
            tableSet(PTS_L3_1, i, .{ .rwx = .ro, .u = 0, .g = 0, .a = 1, .d = 1, .ppn = @truncate(u44, address >> PAGING.page_bits) });
            address += PAGING.page_size;
        }
    }

    // Map framebuffer as device.  Put in second/third PTS_L3 as it tends to be
    // huge and probably benefits from the larger alignment.
    if (new_entry.fb) |base| {
        i = 512;
        address = @ptrToInt(base);
        new_entry.fb = @intToPtr([*]u32, PAGING.kernelPageAddress(i));
        var new_end = i + (new_entry.fb_vert * new_entry.fb_horiz * 4 + PAGING.page_size - 1) / PAGING.page_size;
        entryAssert(new_end <= 512 + 512 * 2, "end got too big (4)");

        hw.entry_uart.carefully(.{ "MAP: FB at     ", PAGING.kernelPageAddress(i), "~\r\n" });
        while (i < new_end) : (i += 1) {
            if (i - 512 < 512) {
                tableSet(PTS_L3_2, i - 512, .{ .rwx = .rw, .u = 0, .g = 0, .a = 1, .d = 1, .ppn = @truncate(u44, address >> PAGING.page_bits) });
            } else {
                tableSet(PTS_L3_3, i - 1024, .{ .rwx = .rw, .u = 0, .g = 0, .a = 1, .d = 1, .ppn = @truncate(u44, address >> PAGING.page_bits) });
            }
            address += PAGING.page_size;
        }
    }
    hw.entry_uart.carefully(.{ "MAP: end at    ", PAGING.kernelPageAddress(i), ".\r\n" });

    hw.entry_uart.carefully(.{ "about to install:\r\nsp: ", new_sp, "\r\n" });
    hw.entry_uart.carefully(.{ "ra: ", daintree_main - daintree_base + PAGING.kernel_base, "\r\n" });
    hw.entry_uart.carefully(.{ "uart mapped to: ", PAGING.kernelPageAddress(end), "\r\n" });

    const satp = (SATP{
        .ppn = @truncate(u44, @ptrToInt(PT_L1) >> PAGING.page_bits),
        .asid = 0,
        .mode = .sv39,
    }).toU64();

    asm volatile (
        \\mv sp, %[sp]
        \\csrw satp, %[satp]
        \\sfence.vma
        \\ret
        :
        : [sp] "{a0}" (new_sp), // Argument to daintree_main.
          [satp] "r" (satp),
          [ra] "{ra}" (daintree_main - daintree_base + PAGING.kernel_base)
        : "memory"
    );

    unreachable;
}
