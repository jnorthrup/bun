# Bun Rust Confluence - Phase 2: FFI Bridge Implementation

**Status:** 🔄 IN PROGRESS
**Started:** 2026-03-15
**Priority:** CRITICAL - System stability issue

## Objective

Fix critical race conditions and memory leaks in Bun's ObjectPool by creating an FFI bridge to Rust's lock-free AtomicPool.

## Problem Statement

Bun's `src/pool.zig` ObjectPool has critical race conditions:

1. **Thread-unsafe global state** (lines 133-145):
   ```zig
   threadlocal var data_threadlocal: DataStructThreadLocal = DataStructThreadLocal{};
   var data__: DataStructNonThreadLocal = DataStructNonThreadLocal{};
   ```
   - Non-atomic access to global state
   - Concurrent `push()` operations corrupt linked list

2. **Non-atomic pool operations**:
   - `push()` calls `prepend()` without synchronization
   - `get()` calls `popFirst()` without atomic operations
   - `loaded` flag and `count` are not atomic

3. **Memory leak** (line 252 comment acknowledges this)

## Solution

Replace Bun ObjectPool with Rust AtomicPool via FFI:
- **Rust side**: Lock-free AtomicPool using crossbeam::SegQueue
- **FFI layer**: C ABI between Zig and Rust
- **Bun side**: Safe Zig wrapper around FFI calls

## Implementation

### Step 1: Create Rust FFI Library ✅ DONE

Created `src/rust_pool_ffi/src/lib.rs` with:
- `pool_create()` - Create new pool
- `pool_get()` - Get object from pool (or create new)
- `pool_put()` - Return object to pool
- `pool_destroy()` - Cleanup pool

### Step 2: Build Configuration 🔄 IN PROGRESS

Need to update:
- `CMakeLists.txt` - Build Rust library as cdylib
- `build.zig` - Link Rust library
- `src/rust_pool_ffi/Cargo.toml` - Library configuration

### Step 3: Zig FFI Bindings 📋 PENDING

Create `src/bun.js/bindings/rust_pool.zig`:
- Declare external Rust functions
- Safe Zig wrapper API
- Error handling

### Step 4: Replace ObjectPool Usage 📋 PENDING

Find and replace all ObjectPool instantiations with RustPool.

## Verification

```bash
# Build with Rust pool
bun bd

# Test thread safety
bun bd test test/js/bun/rust_pool.test.ts

# Check for memory leaks
leaks --atExit -- ./build/debug/bun-debug test/js/bun/rust_pool.test.ts
```

## Files

- `src/rust_pool_ffi/Cargo.toml` - Rust library config
- `src/rust_pool_ffi/src/lib.rs` - FFI exports
- `src/bun.js/bindings/rust_pool.zig` - Zig bindings (to create)
- `src/pool.zig` - Original ObjectPool (to deprecate)

## References

- Literbike AtomicPool: `/Users/jim/work/literbike/src/json/pool.rs`
- Bun ObjectPool: `/Users/jim/work/bun/src/pool.zig`
- Userspace fixes: `/Users/jim/work/userspace/src/concurrency/channels/channel.rs`
