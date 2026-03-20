const std = @import("std");
const builtin = @import("builtin");

const ErrorEntry = struct {
    pc: usize,
    error_type: []const u8,
    addr: usize,
    thread: []const u8,
    access_type: []const u8,
    stack_frames: std.ArrayList(usize),
    symbolicated: ?SymbolInfo = null,

    const SymbolInfo = struct {
        file: []const u8,
        line: u32,
        module: []const u8,
        function: []const u8,
        offset: u64,
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var seen = std.AutoHashMap(usize, void).init(alloc);
    defer seen.deinit();

    var errors = std.ArrayList(ErrorEntry){};
    defer errors.deinit(alloc);

    // Find bun-debug binary
    const bun_binary = findBunDebugBinary(alloc);

    // Read all asan*.txt files
    var dir = std.fs.cwd().openDir(".", .{}) catch |err| {
        std.debug.print("Failed to open dir: {}\n", .{err});
        return;
    };
    defer dir.close();

    var walker = dir.walk(alloc) catch |err| {
        std.debug.print("Failed to walk dir: {}\n", .{err});
        return;
    };
    defer walker.deinit();

    var file_count: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind == .file and
            (std.mem.startsWith(u8, entry.basename, "asan") or
             std.mem.indexOf(u8, entry.basename, "asan") != null))
        {
            // Match asan*.txt*, asan.*, asan*.log
            const is_txt = std.mem.indexOf(u8, entry.basename, ".txt") != null;
            const is_log = std.mem.endsWith(u8, entry.basename, ".log");
            const is_asan_num = std.mem.startsWith(u8, entry.basename, "asan.") and 
                                std.mem.indexOfScalar(u8, entry.basename, '.') != null;
            
            if (is_txt or is_log or is_asan_num) {
                file_count += 1;
                const content = dir.readFileAlloc(alloc, entry.path, 10 * 1024 * 1024) catch |err| {
                    std.debug.print("Failed to read {s}: {}\n", .{ entry.path, err });
                    continue;
                };
                defer alloc.free(content);

                try parseAsanOutput(content, alloc, &seen, &errors);
            }
        }
    }

    std.debug.print("\n", .{});
    std.debug.print("╔═══════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           🩺 ASAN Error Tracker                       ║\n", .{});
    std.debug.print("╚═══════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
    std.debug.print("📁 Files scanned:  {d}\n", .{file_count});
    std.debug.print("🔍 Unique errors:  {d}\n\n", .{errors.items.len});

    if (errors.items.len > 0) {
        if (bun_binary) |binary| {
            std.debug.print("🔨 Symbolicating with: {s}\n\n", .{binary});
            try symbolicateErrors(alloc, &errors, binary);
            alloc.free(binary);
        } else {
            std.debug.print("⚠️  No bun-debug binary found. Run without symbolication.\n\n", .{});
        }
    }

    // Print detailed report
    for (errors.items, 0..) |e, i| {
        const icon = if (std.mem.startsWith(u8, e.error_type, "detected")) "💧" else "💥";
        
        std.debug.print("═══════════════════════════════════════════════════════\n", .{});
        std.debug.print("{s} [{d}] {s}\n", .{ icon, i, e.error_type });
        std.debug.print("═══════════════════════════════════════════════════════\n", .{});
        std.debug.print("  📍 Address: 0x{X}\n", .{e.addr});
        std.debug.print("  💻 PC:      0x{X}\n", .{e.pc});
        if (e.thread.len > 0 and !std.mem.eql(u8, e.thread, "unknown")) {
            std.debug.print("  🧵 Thread:  {s}\n", .{e.thread});
        }
        if (e.access_type.len > 0 and !std.mem.eql(u8, e.access_type, "unknown")) {
            std.debug.print("  📝 Access:  {s}\n", .{e.access_type});
        }
        std.debug.print("\n", .{});

        if (e.symbolicated) |sym| {
            std.debug.print("  📍 Source Location:\n", .{});
            
            // Truncate long C++ function names
            const max_func_len = 120;
            if (sym.function.len > max_func_len) {
                std.debug.print("     {s}...\n", .{sym.function[0..max_func_len]});
            } else {
                std.debug.print("     {s}\n", .{sym.function});
            }
            
            if (sym.module.len > 0 and !std.mem.eql(u8, sym.module, "???")) {
                std.debug.print("     in {s} (+0x{X})\n", .{ sym.module, sym.offset });
            }
            std.debug.print("\n", .{});
        } else if (bun_binary != null) {
            std.debug.print("  ⚠️  Could not resolve source location\n\n", .{});
        }

        if (e.stack_frames.items.len > 0) {
            const show_frames = @min(e.stack_frames.items.len, 20);
            std.debug.print("  📚 Stack trace (showing {d}/{d} frames):\n", .{ show_frames, e.stack_frames.items.len });
            for (e.stack_frames.items[0..show_frames], 0..) |frame_pc, idx| {
                const marker = if (idx == 0) " ← TOP" else "";
                std.debug.print("    [{d}] 0x{X}{s}\n", .{ idx, frame_pc, marker });
            }
            if (e.stack_frames.items.len > show_frames) {
                std.debug.print("    ... and {d} more frames\n", .{e.stack_frames.items.len - show_frames});
            }
            std.debug.print("\n", .{});
        }
    }

    if (errors.items.len == 0) {
        std.debug.print("✅ No ASAN errors found.\n", .{});
    } else {
        std.debug.print("═══════════════════════════════════════════════════════\n", .{});
        std.debug.print("📊 Summary: {d} unique error(s)\n", .{errors.items.len});
        
        // Group by error type
        var by_type = std.StringHashMap(usize).init(alloc);
        defer by_type.deinit();
        for (errors.items) |e| {
            const cnt = by_type.get(e.error_type) orelse 0;
            try by_type.put(e.error_type, cnt + 1);
        }
        
        std.debug.print("\n📁 By type:\n", .{});
        var it = by_type.iterator();
        while (it.next()) |entry| {
            std.debug.print("   • {s}: {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        // Count symbolicated
        var symbolicated_count: usize = 0;
        for (errors.items) |e| {
            if (e.symbolicated != null) symbolicated_count += 1;
        }
        std.debug.print("\n🔍 Symbolicated: {d}/{d}\n", .{ symbolicated_count, errors.items.len });
    }

    std.debug.print("\n", .{});

    // Cleanup
    for (errors.items) |*e| {
        alloc.free(e.error_type);
        if (!std.mem.eql(u8, e.thread, "unknown")) {
            alloc.free(e.thread);
        }
        e.stack_frames.deinit(alloc);
        if (e.symbolicated) |sym| {
            alloc.free(sym.file);
            alloc.free(sym.module);
            alloc.free(sym.function);
        }
    }
}

fn findBunDebugBinary(alloc: std.mem.Allocator) ?[]const u8 {
    const paths = [_][]const u8{
        "./build/debug/bun-debug",
        "../build/debug/bun-debug",
        "./bun-debug",
        "./build/release-asan/bun-asan",
        "./build/release-asan/bun",
    };

    for (&paths) |path| {
        std.fs.cwd().access(path, .{}) catch continue;
        return alloc.dupe(u8, path) catch return null;
    }
    return null;
}

fn parseAsanOutput(
    content: []const u8,
    alloc: std.mem.Allocator,
    seen: *std.AutoHashMap(usize, void),
    errors: *std.ArrayList(ErrorEntry),
) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var current_error: ?ErrorEntry = null;
    var prev_was_error_line = false;

    while (lines.next()) |line| {
        // Skip SUMMARY lines
        if (std.mem.startsWith(u8, line, "SUMMARY:")) continue;
        
        // Check for error header (AddressSanitizer or LeakSanitizer)
        if (std.mem.indexOf(u8, line, "Sanitizer:")) |_| {
            // Save previous error if exists
            if (current_error) |*e| {
                // For LeakSanitizer or errors without PC, try to get PC from first stack frame
                if (e.pc == 0 and e.stack_frames.items.len > 0) {
                    e.pc = e.stack_frames.items[0];
                }
                
                if (!seen.contains(e.pc)) {
                    try seen.put(e.pc, {});
                    try errors.append(alloc, e.*);
                } else {
                    e.stack_frames.deinit(alloc);
                    alloc.free(e.error_type);
                    if (!std.mem.eql(u8, e.thread, "unknown")) alloc.free(e.thread);
                    if (!std.mem.eql(u8, e.access_type, "unknown")) alloc.free(e.access_type);
                }
            }

            // Parse new error
            current_error = try parseErrorLine(line, alloc);
            prev_was_error_line = true;
        } else if (current_error != null and prev_was_error_line) {
            // Next line after error header has access type and thread
            // Format: "READ of size 1 at 0xADDR thread T6"
            if (std.mem.startsWith(u8, line, "READ")) {
                current_error.?.access_type = "READ";
            } else if (std.mem.startsWith(u8, line, "WRITE")) {
                current_error.?.access_type = "WRITE";
            }
            
            if (std.mem.indexOf(u8, line, "thread T")) |idx| {
                const thread_start = idx + "thread ".len;
                const new_thread = alloc.dupe(u8, line[thread_start..]) catch null;
                if (new_thread) |t| {
                    if (!std.mem.eql(u8, current_error.?.thread, "unknown")) {
                        alloc.free(current_error.?.thread);
                    }
                    current_error.?.thread = t;
                }
            }
            prev_was_error_line = false;
        } else if (current_error != null and std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), "#")) {
            // Stack trace frame: #0 0x7fff5a9b4c0d in function_name+0x123
            if (try parseStackFrame(line)) |frame_pc| {
                try current_error.?.stack_frames.append(alloc, frame_pc);
            }
        } else {
            prev_was_error_line = false;
        }
    }

    // Don't forget the last error
    if (current_error) |*e| {
        // For LeakSanitizer or errors without PC, try to get PC from first stack frame
        if (e.pc == 0 and e.stack_frames.items.len > 0) {
            e.pc = e.stack_frames.items[0];
        }
        
        if (!seen.contains(e.pc)) {
            try seen.put(e.pc, {});
            try errors.append(alloc, e.*);
        } else {
            e.stack_frames.deinit(alloc);
            alloc.free(e.error_type);
            if (!std.mem.eql(u8, e.thread, "unknown")) alloc.free(e.thread);
            if (!std.mem.eql(u8, e.access_type, "unknown")) alloc.free(e.access_type);
        }
    }
}

fn parseErrorLine(line: []const u8, alloc: std.mem.Allocator) !ErrorEntry {
    // Format 1: ==89035==ERROR: AddressSanitizer: use-after-poison on address 0xADDR at pc 0xPC ...
    // Format 2: ==66758==ERROR: LeakSanitizer: detected memory leaks
    const addr_san_start = std.mem.indexOf(u8, line, "AddressSanitizer: ");
    const leak_san_start = std.mem.indexOf(u8, line, "LeakSanitizer:");
    
    const san_start = addr_san_start orelse leak_san_start orelse {
        return .{
            .pc = 0,
            .error_type = try alloc.dupe(u8, "unknown"),
            .addr = 0,
            .thread = try alloc.dupe(u8, "unknown"),
            .access_type = try alloc.dupe(u8, "unknown"),
            .stack_frames = std.ArrayList(usize){},
            .symbolicated = null,
        };
    };
    
    // Find "Sanitizer: " and get error type after it
    const san_label = "Sanitizer: ";
    const san_idx = std.mem.indexOf(u8, line[san_start..], san_label) orelse san_start;
    const after_prefix = line[san_start + san_idx + san_label.len..];
    var it = std.mem.tokenizeScalar(u8, after_prefix, ' ');

    const err_type = it.next() orelse "unknown";
    
    // For AddressSanitizer: parse address and pc
    var addr: usize = 0;
    var pc: usize = 0;
    
    if (std.mem.startsWith(u8, err_type, "use-after-") or 
        std.mem.startsWith(u8, err_type, "heap-buffer-") or
        std.mem.startsWith(u8, err_type, "stack-buffer-") or
        std.mem.startsWith(u8, err_type, "global-buffer-")) 
    {
        _ = it.next(); // "on"
        _ = it.next(); // "address"
        const addr_str = it.next() orelse "0x0";
        addr = std.fmt.parseInt(usize, addr_str["0x".len..], 16) catch 0;
        _ = it.next(); // "at"
        _ = it.next(); // "pc"
        const pc_str = it.next() orelse "0x0";
        pc = std.fmt.parseInt(usize, pc_str["0x".len..], 16) catch 0;
    }
    // For LeakSanitizer: "detected memory leaks" - PC comes from stack trace

    // Look for thread info in original line
    var thread: []const u8 = "unknown";
    if (std.mem.indexOf(u8, line, "thread T")) |idx| {
        const thread_start = idx + "thread ".len;
        thread = alloc.dupe(u8, line[thread_start..]) catch "unknown";
    }

    const access_type: []const u8 = "unknown";
    const stack_frames = std.ArrayList(usize){};

    return .{
        .pc = pc,
        .error_type = try alloc.dupe(u8, err_type),
        .addr = addr,
        .thread = thread,
        .access_type = access_type,
        .stack_frames = stack_frames,
        .symbolicated = null,
    };
}

fn parseStackFrame(line: []const u8) !?usize {
    // Format: #0 0x7fff5a9b4c0d in function_name+0x123
    // or:     #1 0x100001234 (bun-debug+0x1234)
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "#")) return null;
    
    var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
    _ = it.next(); // "#0"
    const pc_str = it.next() orelse return null;
    
    if (!std.mem.startsWith(u8, pc_str, "0x")) return null;
    return std.fmt.parseInt(usize, pc_str["0x".len..], 16) catch null;
}

fn symbolicateErrors(
    alloc: std.mem.Allocator,
    errors: *std.ArrayList(ErrorEntry),
    binary: []const u8,
) !void {
    for (errors.items) |*e| {
        // For LeakSanitizer, top frames are in ASAN runtime
        // Try to find first frame from the application binary
        
        // If no symbolication from top PC, try stack frames
        if (try symbolicatePC(alloc, e.pc, binary)) |sym| {
            e.symbolicated = sym;
        } else if (e.stack_frames.items.len > 0) {
            // Try each frame until we find one from the application
            for (e.stack_frames.items) |frame_pc| {
                if (try symbolicatePC(alloc, frame_pc, binary)) |sym| {
                    e.symbolicated = sym;
                    break;
                }
            }
        }
    }
}

fn symbolicatePC(
    alloc: std.mem.Allocator,
    pc: usize,
    binary: []const u8,
) !?ErrorEntry.SymbolInfo {
    // Use atos on macOS
    if (builtin.os.tag == .macos) {
        const pc_str = try std.fmt.allocPrint(alloc, "0x{X}", .{pc});
        defer alloc.free(pc_str);
        
        const result = try std.process.Child.run(.{
            .allocator = alloc,
            .argv = &[_][]const u8{ 
                "atos", 
                "-o", binary, 
                "-l", "0x100000000", 
                pc_str
            },
            .max_output_bytes = 4096,
        });
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);

        if (result.term.Exited == 0 and result.stdout.len > 0) {
            // Parse atos output: "function_name (in module) + offset"
            const stdout_trimmed = std.mem.trimRight(u8, result.stdout, " \n\r");
            
            // Skip if it's just the address (no symbol info)
            if (std.mem.startsWith(u8, stdout_trimmed, "0x")) return null;
            
            var function: []const u8 = stdout_trimmed;
            var module: []const u8 = "???";
            var offset: u64 = 0;
            
            // Parse: "function (in module) + offset"
            if (std.mem.indexOf(u8, stdout_trimmed, " (in ")) |in_idx| {
                function = stdout_trimmed[0..in_idx];
                
                // Find module name between "in " and ")"
                const after_in = stdout_trimmed[in_idx + " (in ".len..];
                if (std.mem.indexOfScalar(u8, after_in, ')')) |close_idx| {
                    module = after_in[0..close_idx];
                    
                    // Check for "+ offset" after the closing paren
                    const after_paren = stdout_trimmed[in_idx + " (in ".len + close_idx + 1..];
                    const trimmed_after = std.mem.trimLeft(u8, after_paren, " ");
                    if (std.mem.startsWith(u8, trimmed_after, "+")) {
                        offset = std.fmt.parseInt(u64, trimmed_after[1..], 16) catch 0;
                    }
                }
            }
            
            // For C++ code, we don't have file:line info from atos
            // Use the module name as a fallback for "file"
            return .{
                .file = try alloc.dupe(u8, module),
                .line = 0,
                .module = try alloc.dupe(u8, module),
                .function = try alloc.dupe(u8, function),
                .offset = offset,
            };
        }
    }

    return null;
}
