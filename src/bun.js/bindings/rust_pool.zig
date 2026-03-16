//! Rust Pool FFI bindings for Bun
//!
//! This module provides safe Zig wrappers around the Rust AtomicPool FFI.
//! It replaces Bun's thread-unsafe ObjectPool with a lock-free implementation.

const std = @import("std");
const bun = @import("bun");

/// Opaque handle to a Rust pool (from bun_pool_ffi)
pub const PoolHandle = opaque {};

/// FFI function declarations
extern "C" fn bun_pool_create() ?*PoolHandle;
extern "C" fn bun_pool_create_max(max_size: usize) ?*PoolHandle;
extern "C" fn bun_pool_get(handle: ?*PoolHandle) ?*anyopaque;
extern "C" fn bun_pool_put(handle: ?*PoolHandle, obj: ?*anyopaque) void;
extern "C" fn bun_pool_size(handle: ?*PoolHandle) usize;
extern "C" fn bun_pool_total_created(handle: ?*PoolHandle) usize;
extern "C" fn bun_pool_clear(handle: ?*PoolHandle) void;
extern "C" fn bun_pool_destroy(handle: ?*PoolHandle) void;

/// Thread-safe wrapper around Rust AtomicPool
pub const RustPool = struct {
    handle: ?*PoolHandle,

    /// Create a new pool with default max size (1000)
    pub fn init() RustPool {
        const handle = bun_pool_create() orelse {
            @panic("Failed to create Rust pool");
        };
        return .{ .handle = handle };
    }

    /// Create a new pool with specified max size
    /// This prevents memory leaks by limiting pool growth
    pub fn initWithMaxSize(max_size: usize) RustPool {
        const handle = bun_pool_create_max(max_size) orelse {
            @panic("Failed to create Rust pool with max size");
        };
        return .{ .handle = handle };
    }

    /// Deinitialize the pool
    pub fn deinit(self: *RustPool) void {
        if (self.handle) |h| {
            bun_pool_destroy(h);
            self.handle = null;
        }
    }

    /// Get an object from the pool, or create a new one if empty
    pub fn get(self: *const RustPool) ?*anyopaque {
        return bun_pool_get(self.handle);
    }

    /// Return an object to the pool
    pub fn put(self: *const RustPool, obj: ?*anyopaque) void {
        bun_pool_put(self.handle, obj);
    }

    /// Get the number of objects currently in the pool
    pub fn size(self: *const RustPool) usize {
        return bun_pool_size(self.handle);
    }

    /// Get the total number of objects created
    pub fn totalCreated(self: *const RustPool) usize {
        return bun_pool_total_created(self.handle);
    }

    /// Clear all objects from the pool
    pub fn clear(self: *const RustPool) void {
        bun_pool_clear(self.handle);
    }
};

/// Generic type-safe wrapper for RustPool
pub fn TypedPool(comptime T: type) type {
    return struct {
        pool: RustPool,

        /// Create a new typed pool
        pub fn init() @This() {
            return .{ .pool = RustPool.init() };
        }

        /// Deinitialize the pool
        pub fn deinit(self: *@This()) void {
            self.pool.deinit();
        }

        /// Get an object from the pool, or create a new one if empty
        pub fn get(self: *@This()) ?*T {
            if (bun_pool_get(self.pool.handle)) |ptr| {
                return @ptrCast(@alignCast(ptr));
            }
            return null;
        }

        /// Create a new object (when pool is empty)
        pub fn create(_: *@This(), allocator: std.mem.Allocator) !T {
            return allocator.create(T);
        }

        /// Return an object to the pool
        pub fn put(self: *@This(), obj: *T) void {
            bun_pool_put(self.pool.handle, obj);
        }

        /// Get the number of objects in the pool
        pub fn size(self: *const @This()) usize {
            return self.pool.size();
        }

        /// Get the total number of objects created
        pub fn totalCreated(self: *const @This()) usize {
            return self.pool.totalCreated();
        }
    };
}

// Tests
test "RustPool basic operations" {
    var pool = RustPool.init();
    defer pool.deinit();

    // Initially empty
    try std.testing.expectEqual(@as(usize, 0), pool.size());

    // Get from empty pool returns null
    const obj1 = pool.get();
    try std.testing.expect(obj1 == null);

    // Put an object
    const dummy_ptr: *anyopaque = @ptrFromInt(0x1000);
    pool.put(dummy_ptr);

    // Now size should be 1
    try std.testing.expectEqual(@as(usize, 1), pool.size());

    // Get should return it
    _ = pool.get();
    try std.testing.expect(obj1 != null); // Should not be null anymore
}

test "TypedPool basic operations" {
    const Dummy = struct { value: u32 };

    var pool = TypedPool(Dummy).init();
    defer pool.deinit();

    // Initially empty
    try std.testing.expectEqual(@as(usize, 0), pool.size());

    // Get from empty pool returns null
    const obj1 = pool.get();
    try std.testing.expect(obj1 == null);

    // Create a new object
    const obj2 = try pool.create(std.testing.allocator);
    obj2.value = 42;

    // Return it to pool
    pool.put(obj2);

    // Now size should be 1
    try std.testing.expectEqual(@as(usize, 1), pool.size());

    // Get should return it
    const obj3 = pool.get();
    try std.testing.expect(obj3 != null);
    try std.testing.expectEqual(@as(u32, 42), obj3.?.value);
}

/// Drop-in replacement for Bun's ObjectPool
/// Maintains the same API but delegates to thread-safe Rust AtomicPool
/// This eliminates race conditions and memory leaks
pub fn ObjectPool(
    comptime Type: type,
    comptime Init: (?fn (std.mem.Allocator) anyerror!Type),
    comptime threadsafe: bool,
    comptime max_count: comptime_int,
) type {
    _ = threadsafe;
    return struct {
        const Pool = @This();
        const LinkedList = struct {
            first: ?*Node = null,

            pub fn prepend(list: *LinkedList, new_node: *Node) void {
                new_node.next = list.first;
                list.first = new_node;
            }

            pub fn popFirst(list: *LinkedList) ?*Node {
                const first_node = list.first orelse return null;
                list.first = first_node.next;
                return first_node;
            }
        };

        pub const Node = struct {
            next: ?*Node = null,
            allocator: std.mem.Allocator,
            data: Type,

            /// Release this node back to the pool
            pub fn release(node: *Node) void {
                Pool.release(node);
            }
        };

        pub const List = LinkedList;
        
        rust_pool: RustPool,
        allocator: std.mem.Allocator,
        max_size: usize,
        
        var rust_pool_instance: ?RustPool = null;
        var rust_pool_initialized = false;

        pub fn initPool(allocator: std.mem.Allocator) Pool {
            if (!rust_pool_initialized) {
                const max_size = if (max_count > 0) max_count else 1000;
                rust_pool_instance = RustPool.initWithMaxSize(max_size);
                rust_pool_initialized = true;
            }
            return .{
                .rust_pool = rust_pool_instance.?,
                .allocator = allocator,
                .max_size = if (max_count > 0) max_count else 1000,
            };
        }

        pub fn full() bool {
            if (max_count == 0) return false;
            return rust_pool_instance.?.size() >= max_count;
        }

        pub fn has() bool {
            return rust_pool_instance.?.size() > 0;
        }

        pub fn push(allocator: std.mem.Allocator, pooled: Type) void {
            _ = initPool(allocator); // Initialize pool if needed

            const new_node = allocator.create(Node) catch unreachable;
            new_node.* = Node{
                .allocator = allocator,
                .data = pooled,
            };
            release(new_node);
        }

        pub fn getIfExists() ?*Node {
            if (!rust_pool_initialized) return null;
            if (rust_pool_instance.?.get()) |ptr| {
                const node = @as(*Node, @ptrCast(@alignCast(ptr)));
                if (comptime std.meta.hasFn(Type, "reset")) node.data.reset();
                return node;
            }
            return null;
        }

        pub fn first(allocator: std.mem.Allocator) *Type {
            return &get(allocator).data;
        }

        pub fn get(allocator: std.mem.Allocator) *Node {
            _ = initPool(allocator); // Initialize pool if needed

            if (rust_pool_instance.?.get()) |ptr| {
                const node = @as(*Node, @ptrCast(@alignCast(ptr)));
                if (comptime std.meta.hasFn(Type, "reset")) node.data.reset();
                return node;
            }

            if (comptime log_allocations) std.fs.File.stderr().writeAll(comptime std.fmt.comptimePrint("Allocate {s} - {d} bytes\n", .{ @typeName(Type), @sizeOf(Type) })) catch {};

            const new_node = allocator.create(Node) catch unreachable;
            new_node.* = Node{
                .allocator = allocator,
                .data = if (comptime Init) |init_|
                    (init_(allocator) catch unreachable)
                else
                    undefined,
            };

            return new_node;
        }

        pub fn releaseValue(value: *Type) void {
            @as(*Node, @fieldParentPtr("data", value)).release();
        }

        pub fn release(node: *Node) void {
            if (!rust_pool_initialized) {
                rust_pool_instance = RustPool.initWithMaxSize(if (max_count > 0) max_count else 1000);
                rust_pool_initialized = true;
            }

            if (comptime max_count > 0) {
                if (rust_pool_instance.?.size() >= max_count) {
                    if (comptime log_allocations) std.fs.File.stderr().writeAll(comptime std.fmt.comptimePrint("Free {s} - {d} bytes\n", .{ @typeName(Type), @sizeOf(Type) })) catch {};
                    destroyNode(node);
                    return;
                }
            }

            rust_pool_instance.?.put(node);
        }

        pub fn deleteAll() void {
            if (!rust_pool_initialized) return;
            rust_pool_instance.?.clear();
        }

        fn destroyNode(node: *Node) void {
            if (comptime Type != bun.ByteList) {
                bun.memory.deinit(&node.data);
            }
            node.allocator.destroy(node);
        }
    };
}

const log_allocations = false;
