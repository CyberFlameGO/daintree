const std = @import("std");
const uefi = std.os.uefi;
const build_options = @import("build_options");
const elf = @import("elf.zig");

var con_out: *uefi.protocols.SimpleTextOutputProtocol = undefined;
var boot_services: *uefi.tables.BootServices = undefined;

fn puts(msg: []const u8) void {
    for (msg) |c| {
        const c_ = [2]u16{ c, 0 };
        _ = con_out.outputString(@ptrCast(*const [1:0]u16, &c_));
    }
}

fn printf(comptime format: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    puts(std.fmt.bufPrint(buf[0..], format, args) catch unreachable);
}

fn haltMsg(comptime msg: []const u8) noreturn {
    puts("halted: " ++ msg ++ "\r\n");
    halt();
}

fn halt() noreturn {
    asm volatile ("msr daifset, #15");
    while (true) {
        asm volatile ("wfi");
    }
}

fn check(comptime method: []const u8, result: uefi.Status) void {
    if (result != .Success) {
        haltMsg(method ++ " failed");
    }
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace) noreturn {
    printf("panic: {s}\n", .{msg});
    asm volatile ("b .");
    unreachable;
}

pub fn main() void {
    con_out = uefi.system_table.con_out.?;
    boot_services = uefi.system_table.boot_services.?;

    printf("daintree bootloader {s} on {s}\r\n", .{ build_options.version, build_options.board });

    var li_proto: ?*uefi.protocols.LoadedImageProtocol = undefined;
    if (boot_services.openProtocol(
        uefi.handle,
        &uefi.protocols.LoadedImageProtocol.guid,
        @ptrCast(*?*c_void, &li_proto),
        uefi.handle,
        null,
        .{ .get_protocol = true },
    ) == .Success) {
        var buffer: [256]u8 = [_]u8{undefined} ** 256;
        const options_size = li_proto.?.load_options_size;
        if (options_size > 0) {
            var ptr: [*]u16 = @ptrCast([*]u16, @alignCast(@alignOf([*]u16), li_proto.?.load_options.?));
            if (std.unicode.utf16leToUtf8(&buffer, ptr[0 .. options_size / 2])) |sz| {
                var options = buffer[0..sz];
                if (options.len > 0 and options[options.len - 1] == 0) {
                    options = options[0 .. options.len - 1];
                }
                handleOptions(options);
            } else |err| {
                printf("failed utf16leToUtf8: {}\n", .{err});
            }
        }
    }

    // find traversable filesystems

    var handle_list_size: usize = 0;
    var handle_list: [*]uefi.Handle = undefined;
    while (boot_services.locateHandle(
        .ByProtocol,
        &uefi.protocols.SimpleFileSystemProtocol.guid,
        null,
        &handle_list_size,
        handle_list,
    ) == .BufferTooSmall) {
        check("allocatePool", boot_services.allocatePool(
            uefi.tables.MemoryType.BootServicesData,
            handle_list_size,
            @ptrCast(*[*]align(8) u8, &handle_list),
        ));
    }

    if (handle_list_size == 0) {
        haltMsg("no simple file system protocols found");
    }

    const handle_count = handle_list_size / @sizeOf(uefi.Handle);

    printf("searching for DAINKRNL and DTB on {} volume(s) ", .{handle_count});
    var dainkrnl: ?[]const u8 = null;
    var dainkrnl_elf: ?elf.Header = null;

    var dtb: ?[]const u8 = null;

    for (handle_list[0..handle_count]) |handle| {
        var sfs_proto: ?*uefi.protocols.SimpleFileSystemProtocol = undefined;

        check("openProtocol", boot_services.openProtocol(
            handle,
            &uefi.protocols.SimpleFileSystemProtocol.guid,
            @ptrCast(*?*c_void, &sfs_proto),
            uefi.handle,
            null,
            .{ .get_protocol = true },
        ));

        puts(".");

        var f_proto: *uefi.protocols.FileProtocol = undefined;
        check("openVolume", sfs_proto.?.openVolume(&f_proto));

        if (dainkrnl == null) {
            if (tryLoadFromFileProtocol(f_proto, "dainkrnl")) |bin| {
                dainkrnl = bin;
                dainkrnl_elf = parseElf(bin);
            }
        }
        if (dtb == null) {
            dtb = tryLoadFromFileProtocol(f_proto, "dtb");
        }

        _ = boot_services.closeProtocol(handle, &uefi.protocols.SimpleFileSystemProtocol.guid, uefi.handle, null);

        if (dainkrnl != null and dtb != null) {
            break;
        }
    }

    if (dainkrnl_elf) |dainkrnl_elf_found| {
        if (dtb) |dtb_found| {
            exitBootServices(dainkrnl.?, dainkrnl_elf_found, dtb_found);
        } else {
            puts("\r\nDTB not found\r\n");
        }
    } else {
        puts("\r\nDAINKRNL not found\r\n");
    }
    _ = boot_services.stall(5 * 1000 * 1000);
}

fn tryLoadFromFileProtocol(f_proto: *uefi.protocols.FileProtocol, comptime file_name: []const u8) ?[]const u8 {
    var proto: *uefi.protocols.FileProtocol = undefined;
    var size: u64 = undefined;
    var mem: [*]u8 = undefined;

    const file_name_u16: [:0]const u16 = comptime blk: {
        var n: [:0]const u16 = &[_:0]u16{};
        for (file_name) |c| {
            n = n ++ [_]u16{c};
        }
        break :blk n;
    };

    if (f_proto.open(&proto, file_name_u16, uefi.protocols.FileProtocol.efi_file_mode_read, 0) != .Success) {
        return null;
    }

    check("setPosition", proto.setPosition(uefi.protocols.FileProtocol.efi_file_position_end_of_file));
    check("getPosition", proto.getPosition(&size));
    printf(" \"{s}\" {} bytes ", .{ file_name, size });

    check("setPosition", proto.setPosition(0));

    check("allocatePool", boot_services.allocatePool(
        .BootServicesData,
        size,
        @ptrCast(*[*]align(8) u8, &mem),
    ));
    check("read", proto.read(&size, mem));
    return mem[0..size];
}

fn handleOptions(options: []const u8) void {
    var it = std.mem.tokenize(options, " ");
    var dtb: ?[]u8 = null;

    while (it.next()) |opt_name| {
        if (std.mem.eql(u8, opt_name, "dtb")) {
            const loc = handleOptionsLoc("dtb", &it) orelse return;
            printf("using dtb in ramdisk at 0x{x:0>16} ({} bytes)\r\n", .{ loc.offset, loc.len });
            dtb = @intToPtr([*]u8, loc.offset)[0..loc.len];
        } else if (std.mem.eql(u8, opt_name, "ramdisk")) {
            const loc = handleOptionsLoc("ramdisk", &it) orelse return;

            if (dtb == null) {
                printf("can't load kernel in ramdisk without dtb\r\n", .{});
                return;
            }

            printf("loading kernel in ramdisk at 0x{x:0>16} ({} bytes)\r\n", .{ loc.offset, loc.len });

            const dainkrnl = @intToPtr([*]u8, loc.offset)[0..loc.len];
            const dainkrnl_elf = parseElf(dainkrnl);
            exitBootServices(dainkrnl, dainkrnl_elf, dtb.?);
        } else {
            printf("unknown option '{s}'\n", .{opt_name});
        }
    }
}

const Loc = struct {
    offset: u64,
    len: u64,
};

fn handleOptionsLoc(comptime opt_name: []const u8, it: *std.mem.TokenIterator) ?Loc {
    const offset_s = it.next() orelse {
        printf(opt_name ++ ": missing offset argument\n", .{});
        return null;
    };
    const len_s = it.next() orelse {
        printf(opt_name ++ ": missing length argument\n", .{});
        return null;
    };

    if (it.next()) |unexp| {
        printf(opt_name ++ ": unexpected argument '{s}'\n", .{unexp});
        return null;
    }

    const offset = std.fmt.parseInt(u64, offset_s, 0) catch |err| {
        printf(opt_name ++ ": parse offset '{s}' error: {}\n", .{ offset_s, err });
        return null;
    };
    const len = std.fmt.parseInt(u64, len_s, 0) catch |err| {
        printf(opt_name ++ ": parse len '{s}' error: {}\n", .{ len_s, err });
        return null;
    };
    return Loc{ .offset = offset, .len = len };
}

fn parseElf(dainkrnl: []const u8) elf.Header {
    if (dainkrnl.len < @sizeOf(elf.Elf64_Ehdr)) {
        printf("found {} byte(s), too small for ELF header ({} bytes)\r\n", .{ dainkrnl.len, @sizeOf(elf.Elf64_Ehdr) });
        halt();
    }

    var elf_buffer = std.io.fixedBufferStream(dainkrnl);
    var dainkrnl_elf = elf.Header.read(&elf_buffer) catch |err| {
        printf("failed to parse ELF: {}\r\n", .{err});
        halt();
    };

    printf("ELF entrypoint: {x:0>16} ({}-bit {c}E)\r\n", .{
        dainkrnl_elf.entry,
        @as(u8, if (dainkrnl_elf.is_64) 64 else 32),
        @as(u8, if (dainkrnl_elf.endian == .Big) 'B' else 'L'),
    });

    var it = dainkrnl_elf.program_header_iterator(&elf_buffer);
    while (it.next() catch haltMsg("iterating phdr")) |phdr| {
        printf(" * type={x:0>8} off={x:0>16} vad={x:0>16} pad={x:0>16} fsz={x:0>16} msz={x:0>16}\r\n", .{ phdr.p_type, phdr.p_offset, phdr.p_vaddr, phdr.p_paddr, phdr.p_filesz, phdr.p_memsz });
    }

    return dainkrnl_elf;
}

fn exitBootServices(dainkrnl: []const u8, dainkrnl_elf: elf.Header, dtb: []const u8) noreturn {
    var graphics: *uefi.protocols.GraphicsOutputProtocol = undefined;
    check("locateProtocol", boot_services.locateProtocol(&uefi.protocols.GraphicsOutputProtocol.guid, null, @ptrCast(*?*c_void, &graphics)));
    var fb: [*]u8 = @intToPtr([*]u8, graphics.mode.frame_buffer_base);

    var memory_map: [*]uefi.tables.MemoryDescriptor = undefined;
    var memory_map_size: usize = 0;
    var memory_map_key: usize = undefined;
    var descriptor_size: usize = undefined;
    var descriptor_version: u32 = undefined;
    while (boot_services.getMemoryMap(
        &memory_map_size,
        memory_map,
        &memory_map_key,
        &descriptor_size,
        &descriptor_version,
    ) == uefi.Status.BufferTooSmall) {
        check("allocatePool", boot_services.allocatePool(
            uefi.tables.MemoryType.BootServicesData,
            memory_map_size,
            @ptrCast(*[*]align(8) u8, &memory_map),
        ));
    }

    var largest_conventional: ?*uefi.tables.MemoryDescriptor = null;

    printf("descriptor size: {}\r\n", .{descriptor_size});
    var offset: usize = 0;
    var i: usize = 0;
    while (offset < memory_map_size) : ({
        offset += descriptor_size;
        i += 1;
    }) {
        const ptr = @intToPtr(*uefi.tables.MemoryDescriptor, @ptrToInt(memory_map) + offset);
        printf("{:2} {s:23} p=0x{x:0>16} size={x:16} ({} mb starting at {} mb)\r\n", .{ i, @tagName(ptr.type), ptr.physical_start, ptr.number_of_pages << 12, ptr.number_of_pages >> 8, ptr.physical_start >> 20 });
        if (ptr.type == .ConventionalMemory) {
            if (largest_conventional) |current_largest| {
                if (ptr.number_of_pages > current_largest.number_of_pages) {
                    largest_conventional = ptr;
                }
            } else {
                largest_conventional = ptr;
            }
        }
    }

    // Just take the single biggest bit of conventional memory.
    const conventional_start = largest_conventional.?.physical_start;
    const conventional_bytes = largest_conventional.?.number_of_pages << 12;

    printf("Using {}mb of memory starting at 0x{x:0>16}\n", .{ conventional_bytes >> 20, conventional_start });

    // The kernel's text section begins at 0xffffff80_00000000. Adjust those down
    // to conventional_start now.

    var elf_source = std.io.fixedBufferStream(dainkrnl);
    var it = dainkrnl_elf.program_header_iterator(&elf_source);
    while (it.next() catch haltMsg("iterating phdrs (2)")) |phdr| {
        if (phdr.p_type == elf.PT_LOAD) {
            const target = phdr.p_vaddr - 0xffffff80_00000000 + conventional_start;
            printf("loading 0x{x:0>16} bytes at 0x{x:0>16} into 0x{x:0>16}\r\n", .{ phdr.p_filesz, phdr.p_vaddr, target });
            std.mem.copy(u8, @intToPtr([*]u8, target)[0..phdr.p_filesz], dainkrnl[phdr.p_offset .. phdr.p_offset + phdr.p_filesz]);
            if (phdr.p_memsz > phdr.p_filesz) {
                printf("  zeroing {} bytes at end\r\n", .{phdr.p_memsz - phdr.p_filesz});
                std.mem.set(u8, @intToPtr([*]u8, target)[phdr.p_filesz..phdr.p_memsz], 0);
            }
        }
    }

    if (graphics.mode.info.horizontal_resolution != graphics.mode.info.pixels_per_scan_line) {
        haltMsg("horizontal res != pixels per scan line");
    }

    printf("framebuffer is at {*}\r\n", .{fb});
    printf("looking up serial base in DTB ... ", .{});
    const uart_base: u64 = 0;

    printf("exiting boot services\r\n", .{});

    check("exitBootServices", boot_services.exitBootServices(uefi.handle, memory_map_key));

    const adjusted_entry = dainkrnl_elf.entry - 0xffffff80_00000000 + conventional_start;

    // Looks like we're left in EL1. (mrs x2, CurrentEL => x2 = 0x4; PSTATE[3:2] = 0x4 -> EL1)
    // Disable the MMU and pass to DAINKRNL.
    // Also clear x29, x30 so we get nice stacks from QEMU.
    asm volatile (
        \\mov x29, #0
        \\mov x30, #0
        \\mrs x10, sctlr_el1
        \\bic x10, x10, #1
        \\msr sctlr_el1, x10
        \\isb
        \\br x9
        :
        : [memory_map] "{x0}" (memory_map),
          [memory_map_size] "{x1}" (memory_map_size),
          [descriptor_size] "{x2}" (descriptor_size),
          [conventional_start] "{x3}" (conventional_start),
          [conventional_bytes] "{x4}" (conventional_bytes),
          [fb] "{x5}" (fb),
          [vertres] "{x6}" (graphics.mode.info.vertical_resolution),
          [horizres] "{x7}" (graphics.mode.info.horizontal_resolution),
          [uart_base] "{x8}" (uart_base),

          [entry] "{x9}" (adjusted_entry)
        : "memory"
    );

    unreachable;
}
