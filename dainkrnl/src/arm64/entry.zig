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

/// dainboot passes control here.  MMU is **off**.  We are in EL1.
pub export fn daintree_mmu_start(entry_data: *dcommon.EntryData) noreturn {
    hw.entry_uart.init(entry_data);

    const daintree_base = arch.loadAddress("__daintree_base");
    const daintree_rodata_base = arch.loadAddress("__daintree_rodata_base");
    const daintree_data_base = arch.loadAddress("__daintree_data_base");
    const daintree_end = arch.loadAddress("__daintree_end");
    const daintree_main = arch.loadAddress("daintree_main");
    const vbar_el1 = arch.loadAddress("__vbar_el1");
    const current_el = arch.readRegister(.CurrentEL) >> 2;
    const sctlr_el1 = arch.readRegister(.SCTLR_EL1);
    const cpacr_el1 = arch.readRegister(.CPACR_EL1);

    hw.entry_uart.carefully(.{ "__daintree_base: ", daintree_base, "\r\n" });
    hw.entry_uart.carefully(.{ "__daintree_rodata_base: ", daintree_rodata_base, "\r\n" });
    hw.entry_uart.carefully(.{ "__daintree_data_base: ", daintree_data_base, "\r\n" });
    hw.entry_uart.carefully(.{ "__daintree_end: ", daintree_end, "\r\n" });
    hw.entry_uart.carefully(.{ "daintree_main: ", daintree_main, "\r\n" });
    hw.entry_uart.carefully(.{ "__vbar_el1: ", vbar_el1, "\r\n" });
    hw.entry_uart.carefully(.{ "CurrentEL: ", current_el, "\r\n" });
    hw.entry_uart.carefully(.{ "SCTLR_EL1: ", sctlr_el1, "\r\n" });
    hw.entry_uart.carefully(.{ "CPACR_EL1: ", cpacr_el1, "\r\n" });

    const tcr_el1 = comptime (TCR_EL1{
        .ips = .B36,
        .tg1 = .K4,
        .t1sz = 64 - PAGING.address_bits, // in practice: 25
        .tg0 = .K4,
        .t0sz = 64 - PAGING.address_bits,
    }).toU64();
    comptime std.debug.assert(0x00000001_b5193519 == tcr_el1);
    arch.writeRegister(.TCR_EL1, tcr_el1);

    const mair_el1 = comptime (MAIR_EL1{ .index = DEVICE_MAIR_INDEX, .attrs = 0b00 }).toU64() |
        (MAIR_EL1{ .index = MEMORY_MAIR_INDEX, .attrs = 0b1111_1111 }).toU64();
    comptime std.debug.assert(0x00000000_000000ff == mair_el1);
    arch.writeRegister(.MAIR_EL1, mair_el1);

    var bump = paging.BumpAllocator{ .next = daintree_end };
    TTBR0_IDENTITY = bump.alloc(PageTable);
    K_DIRECTORY = bump.alloc(PageTable);
    var l2 = bump.alloc(PageTable);
    var l3 = bump.alloc(PageTable);

    const ttbr0_el1 = @ptrToInt(TTBR0_IDENTITY) | 1;
    const ttbr1_el1 = @ptrToInt(K_DIRECTORY) | 1;
    hw.entry_uart.carefully(.{ "setting TTBR0_EL1: ", ttbr0_el1, "\r\n" });
    hw.entry_uart.carefully(.{ "setting TTBR1_EL1: ", ttbr1_el1, "\r\n" });
    arch.writeRegister(.TTBR0_EL1, ttbr0_el1);
    arch.writeRegister(.TTBR1_EL1, ttbr1_el1);

    // XXX add 100MiB to catch page tables
    var it = PAGING.range(1, entry_data.conventional_start, entry_data.conventional_bytes + 100 * 1048576);
    while (it.next()) |r| {
        hw.entry_uart.carefully(.{ "mapping identity: page ", r.page, " address ", r.address, "\r\n" });
        TTBR0_IDENTITY.map(r.page, r.address, .block, .kernel_promisc);
    }

    K_DIRECTORY.map(0, @ptrToInt(l2), .table, .non_leaf);
    l2.map(0, @ptrToInt(l3), .table, .non_leaf);

    var end: u64 = (daintree_end - daintree_base) >> PAGING.page_bits;
    entryAssert(end <= 512, "end got too big (1)");

    var address = daintree_base;
    var flags: paging.MapFlags = .kernel_code;
    var i: u64 = 0;
    hw.entry_uart.carefully(.{ "MAP: text at   ", PAGING.kernelPageAddress(i), "~\r\n" });
    while (i < end) : (i += 1) {
        if (address >= daintree_data_base) {
            if (flags != .kernel_data) {
                hw.entry_uart.carefully(.{ "MAP: data at   ", PAGING.kernelPageAddress(i), "~\r\n" });
                flags = .kernel_data;
            }
        } else if (address >= daintree_rodata_base) {
            if (flags != .kernel_rodata) {
                hw.entry_uart.carefully(.{ "MAP: rodata at ", PAGING.kernelPageAddress(i), "~\r\n" });
                flags = .kernel_rodata;
            }
        }
        l3.map(i, address, .table, flags);
        address += PAGING.page_size;
    }

    hw.entry_uart.carefully(.{ "MAP: PTs at    ", PAGING.kernelPageAddress(i), "~\r\n" });
    var ttbr0_identity_va = PAGING.kernelPageAddress(i);
    l3.map(i, address, .table, .kernel_data);
    address += PAGING.page_size;
    i += 1;
    l3.map(i, address, .table, .kernel_data);
    address += PAGING.page_size;
    i += 1;

    var k_directory_va = PAGING.kernelPageAddress(i);
    l3.map(i, address, .table, .kernel_data);
    address += PAGING.page_size;
    i += 1;
    l3.map(i, address, .table, .kernel_data);
    address += PAGING.page_size;
    i += 1;

    var l2_va = PAGING.kernelPageAddress(i);
    K_DIRECTORY.setVirt(0, l2_va);
    l3.map(i, address, .table, .kernel_data);
    address += PAGING.page_size;
    i += 1;
    l3.map(i, address, .table, .kernel_data);
    address += PAGING.page_size;
    i += 1;

    var l3x_va = PAGING.kernelPageAddress(i);
    l2.setVirt(0, l3x_va);
    l3.map(i, address, .table, .kernel_data);
    address += PAGING.page_size;
    i += 1;
    l3.map(i, address, .table, .kernel_data);
    address += PAGING.page_size;
    i += 1;

    hw.entry_uart.carefully(.{ "MAP: null at   ", PAGING.kernelPageAddress(i), "\r\n" });
    l3.map(i, 0, .table, .kernel_rodata);
    i += 1;

    end = i + STACK_PAGES;
    hw.entry_uart.carefully(.{ "MAP: stack at  ", PAGING.kernelPageAddress(i), "~\r\n" });
    while (i < end) : (i += 1) {
        l3.map(i, address, .table, .kernel_data);
        address += PAGING.page_size;
    }

    entryAssert(end <= 512, "end got too big (2)");

    // Let's hackily put UART at wherever's next.
    hw.entry_uart.carefully(.{ "MAP: UART at   ", PAGING.kernelPageAddress(i), "\r\n" });
    l3.map(i, entry_data.uart_base, .table, .peripheral);

    // address now points to the stack. make space for common.EntryData, align.
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
        .uart_base = PAGING.kernelPageAddress(i),
        .uart_width = entry_data.uart_width,
        .bump_next = bump.next,
    };

    var new_sp = PAGING.kernelPageAddress(i);
    new_sp -= @sizeOf(dcommon.EntryData);
    new_sp &= ~@as(u64, 15);

    // I hate that I'm doing this. Put the DTB in here.
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
            l3.map(i, address, .table, .kernel_rodata);
            address += PAGING.page_size;
        }
    }

    // Adjust these for paging enable.
    TTBR0_IDENTITY = @intToPtr(*PageTable, ttbr0_identity_va);
    hw.entry_uart.carefully(.{ "changing K_DIRECTORY: ", @ptrToInt(K_DIRECTORY), " -> ", k_directory_va, "\r\n" });
    K_DIRECTORY = @intToPtr(*PageTable, k_directory_va);

    hw.entry_uart.carefully(.{ "MAP: end at    ", PAGING.kernelPageAddress(i), ".\r\n" });
    hw.entry_uart.carefully(.{ "about to install:\r\nsp: ", new_sp, "\r\n" });
    hw.entry_uart.carefully(.{ "lr: ", daintree_main - daintree_base + PAGING.kernel_base, "\r\n" });
    hw.entry_uart.carefully(.{ "vbar_el1: ", vbar_el1 - daintree_base + PAGING.kernel_base, "\r\n" });
    hw.entry_uart.carefully(.{ "uart mapped to: ", PAGING.kernelPageAddress(i), "\r\n" });

    // Control passes to daintree_main.
    asm volatile (
        \\mov sp, %[sp]
        \\mov lr, %[lr]
        \\msr VBAR_EL1, %[vbar_el1]
        \\mov x0, %[sp]
        \\mrs x1, SCTLR_EL1
        \\orr x1, x1, #1
        \\msr SCTLR_EL1, x1
        \\tlbi vmalle1
        \\dsb ish
        \\isb
        \\ret
        :
        : [sp] "r" (new_sp),
          [lr] "r" (daintree_main - daintree_base + PAGING.kernel_base),
          [vbar_el1] "r" (vbar_el1 - daintree_base + PAGING.kernel_base)
    );

    unreachable;
}
