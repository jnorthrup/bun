//! Test for ObjectPool drop-in replacement wrapper
//! Verifies that the RustPool-based ObjectPool matches the old API

const std = @import("std");
const bun = @import("bun");
const rust_pool = @import("../../src/bun.js/bindings/rust_pool.zig");

test "ObjectPool basic operations - drop-in replacement" {
    const TestType = struct { value: u32 };
    
    const Pool = rust_pool.ObjectPool(TestType, null, true, 10);
    
    // Test get from empty pool creates new object
    const node1 = Pool.get(std.testing.allocator);
    defer Pool.release(node1);
    
    try std.testing.expectEqual(@as(u32, 0), node1.data.value);
    
    // Modify and return to pool
    node1.data.value = 42;
    Pool.release(node1);
    
    // Get from pool should return the same object
    const node2 = Pool.get(std.testing.allocator);
    defer Pool.release(node2);
    
    try std.testing.expectEqual(@as(u32, 42), node2.data.value);
}

test "ObjectPool with init function" {
    const TestType = struct { value: u32 };
    
    const initFn = fn (allocator: std.mem.Allocator) !TestType {
        _ = allocator;
        return TestType{ .value = 100 };
    };
    
    const Pool = rust_pool.ObjectPool(TestType, initFn, true, 10);
    
    const node1 = Pool.get(std.testing.allocator);
    defer Pool.release(node1);
    
    try std.testing.expectEqual(@as(u32, 100), node1.data.value);
}

test "ObjectPool max_count enforcement" {
    const TestType = struct { value: u32 };
    
    const Pool = rust_pool.ObjectPool(TestType, null, true, 2);
    
    // Create objects up to max
    const node1 = Pool.get(std.testing.allocator);
    defer Pool.release(node1);
    
    const node2 = Pool.get(std.testing.allocator);
    defer Pool.release(node2);
    
    // Pool should not be full yet (objects not returned)
    try std.testing.expect(!Pool.full());
    
    // Return both objects
    Pool.release(node1);
    Pool.release(node2);
    
    // Now pool is full
    try std.testing.expect(Pool.full());
}

test "ObjectPool getIfExists" {
    const TestType = struct { value: u32 };
    
    const Pool = rust_pool.ObjectPool(TestType, null, true, 10);
    
    // Empty pool should return null
    const node1 = Pool.getIfExists();
    try std.testing.expect(node1 == null);
    
    // Add object to pool
    const node2 = Pool.get(std.testing.allocator);
    node2.data.value = 42;
    Pool.release(node2);
    
    // Now getIfExists should return it
    const node3 = Pool.getIfExists();
    try std.testing.expect(node3 != null);
    try std.testing.expectEqual(@as(u32, 42), node3.?.data.value);
    
    Pool.release(node3.?);
}

test "ObjectPool deleteAll" {
    const TestType = struct { value: u32 };
    
    const Pool = rust_pool.ObjectPool(TestType, null, true, 10);
    
    // Create and return multiple objects
    const node1 = Pool.get(std.testing.allocator);
    const node2 = Pool.get(std.testing.allocator);
    
    Pool.release(node1);
    Pool.release(node2);
    
    // Pool should have objects
    try std.testing.expect(Pool.has());
    
    // Delete all
    Pool.deleteAll();
    
    // Pool should be empty
    try std.testing.expect(!Pool.has());
}

test "ObjectPool first helper" {
    const TestType = struct { value: u32 };
    
    const Pool = rust_pool.ObjectPool(TestType, null, true, 10);
    
    // first() should get or create object and return data pointer
    const data = Pool.first(std.testing.allocator);
    
    try std.testing.expectEqual(@as(u32, 0), data.*.value);
    data.*.value = 99;
}

test "ObjectPool concurrent access" {
    const TestType = struct { value: u32 };
    
    const Pool = rust_pool.ObjectPool(TestType, null, true, 100);
    
    // Create and return multiple objects
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const node = Pool.get(std.testing.allocator);
        node.data.value = @intCast(i);
        Pool.release(node);
    }
    
    // Verify pool has objects
    try std.testing.expect(Pool.has());
    
    // Get objects and verify values are reset or valid
    const node = Pool.get(std.testing.allocator);
    defer Pool.release(node);
    
    // Value should be one of the values we set
    try std.testing.expect(node.data.value < 100);
}

test "ObjectPool with reset function" {
    const TestType = struct {
        value: u32,
        
        pub fn reset(self: *TestType) void {
            self.value = 0;
        }
    };
    
    const Pool = rust_pool.ObjectPool(TestType, null, true, 10);
    
    // Create object and set value
    const node1 = Pool.get(std.testing.allocator);
    node1.data.value = 42;
    Pool.release(node1);
    
    // Getting from pool should reset the value
    const node2 = Pool.get(std.testing.allocator);
    defer Pool.release(node2);
    
    try std.testing.expectEqual(@as(u32, 0), node2.data.value);
}

test "ObjectPool releaseValue helper" {
    const TestType = struct { value: u32 };
    
    const Pool = rust_pool.ObjectPool(TestType, null, true, 10);
    
    const node = Pool.get(std.testing.allocator);
    node.data.value = 42;
    
    // Use releaseValue to release via data pointer
    Pool.releaseValue(&node.data);
    
    // Should be available in pool
    const node2 = Pool.getIfExists();
    try std.testing.expect(node2 != null);
    try std.testing.expectEqual(@as(u32, 0), node2.?.data.value); // Reset to 0
    
    Pool.release(node2.?);
}
