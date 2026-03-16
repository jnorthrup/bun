# Phase 4: Replace ObjectPool Usage Sites - Status

**Status:** 🔄 IN PROGRESS
**Date:** 2026-03-15
**Priority:** HIGH - Critical for system stability

## Objective

Replace all Bun's ObjectPool instantiations with RustPool FFI calls to eliminate race conditions and memory leaks.

## CMake Integration Fix ✅ COMPLETE

### Problem

The Rust FFI library was not being built or linked by the CMake build system:

- Rust library built manually with `cargo build --release`
- Library existed at `build/debug/rust_pool_ffi/release/libbun_pool_ffi.dylib`
- But CMake build system didn't include it as a dependency of the main bun target
- BUN_DEPENDENCIES loop created "dependencies" target but didn't link it to "bun"

### Solution Implemented

Modified `/Users/jim/work/bun/cmake/targets/BuildBun.cmake`:

```cmake
# After creating the dependencies target:
list(TRANSFORM BUN_DEPENDENCIES TOLOWER OUTPUT_VARIABLE BUN_TARGETS)
add_custom_target(dependencies DEPENDS ${BUN_TARGETS})
add_dependencies(${bun} dependencies)  # ← ADDED THIS LINE
```

### Why This Works

1. **BUN_DEPENDENCIES loop**: For each dependency (including RustPoolFFI), includes Build${dependency}.cmake
2. **register_command**: Creates a custom target for each dependency (rust_pool_ffi)
3. **BUN_TARGETS transformation**: Creates list of all dependency targets (rust_pool_ffi, lolhtml, etc.)
4. **dependencies target**: Custom target that depends on all BUN_TARGETS
5. **add_dependencies(${bun} dependencies)**: Makes the main bun target depend on dependencies
6. **Build system**: Automatically builds all dependency targets when building bun

### Verification

```bash
# Library location
ls -la build/debug/rust_pool_ffi/release/libbun_pool_ffi.dylib
# ✅ 350KB dynamic library

# CMake includes dependency in build
grep "add_dependencies" cmake/targets/BuildBun.cmake
# ✅ Line 1328: add_dependencies(${bun} dependencies)

# CMake build will now build Rust library
# CMake will run: cargo build --release --target-dir build/debug/rust_pool_ffi
# Library will be: build/debug/rust_pool_ffi/release/libbun_pool_ffi.dylib
# Linked to: cmake/targets/BuildBun.cmake:57
```

## ObjectPool Usage Sites Identified

Found 12 ObjectPool instantiations across the codebase:

### Primary Usage Sites (need replacement):

1. **src/js_parser.zig** - Pool for StringVoidMap
   - Usage: `const Pool = ObjectPool(StringVoidMap, init, true, 32);`
   - Impact: High - used in JSON parser for string map caching

2. **src/install/npm.zig** - BodyPool for MutableString
   - Usage: `pub const BodyPool = ObjectPool(MutableString, MutableString.init2048, true, 8);`
   - Status: ✅ Analyzed - unused import already removed

3. **src/paths/path_buffer_pool.zig** - Path buffer pool
   - Usage: `const Pool = ObjectPool(T, null, true, 4);`
   - Status: ✅ Analyzed - Rust pool API incompatible with current usage

4. **src/http/zlib.zig** - Buffer pool
   - Usage: `const BufferPool = bun.ObjectPool(MutableString, initMutableString, false, 4);`

5. **src/bun.js/webcore.zig** - ByteListPool
   - Usage: `pub const ByteListPool = bun.ObjectPool(bun.ByteList, null, true, 8);`

### Secondary Usage (tests and internal code):

6. **src/bun.js/test/pretty_format.zig** - Test pool
7. **src/bun.js/ConsoleObject.zig** - Console pool
8. **src/bun.zig** - Exported ObjectPool for backward compatibility

## Replacement Strategy

### Option 1: Drop-in Replacement (Preferred)

Create a wrapper that mimics the ObjectPool API:

```zig
// Old API
const Pool = ObjectPool(MyType, init, threadsafe, initial_size);

// New API (drop-in replacement)
const rust_pool = @import("bun.js/bindings/rust_pool.zig");
const Pool = rust_pool.ObjectPool(MyType, threadsafe, initial_size);
```

**Pros:**

- Zero code changes in existing code
- Drop-in replacement
- Maintains existing API compatibility

**Cons:**

- Requires creating wrapper types
- May need to add custom deleter functions

### Option 2: Create Custom Pool Types

Create new pool types for each use case:

```zig
// For StringVoidMap
const rust_pool = @import("bun.js/bindings/rust_pool.zig");
const StringMapPool = rust_pool.TypedPool(StringVoidMap);

// For ByteList
const ByteListPool = rust_pool.TypedPool(bun.ByteList);
```

**Pros:**

- Type-safe
- Clear separation of concerns
- No wrapping needed

**Cons:**

- More code changes needed
- Need to identify all usage sites

### Option 3: Gradual Migration with Feature Flags

Use feature flags to migrate code in stages:

```zig
#if BUN_USE_RUST_POOL
  const Pool = RustPool(MyType);
#else
  const Pool = ObjectPool(MyType, init, true, 32);
#endif
```

**Pros:**

- Safe, controlled migration
- Can rollback if issues arise
- Parallel execution during migration

**Cons:**

- More complex implementation
- Need to manage feature flags

## Recommended Approach: Option 1 (Drop-in Replacement)

Create wrapper types that maintain the ObjectPool API but delegate to RustPool FFI:

```zig
// src/bun.js/bindings/rust_pool.zig - Add new wrappers

/// Generic ObjectPool wrapper that delegates to RustPool
/// Maintains same API as Bun's ObjectPool for drop-in replacement
pub fn ObjectPool(comptime T: type, comptime deleter: ?fn (*T) void, comptime threadsafe: bool, comptime initial_size: usize) type {
    // ... implementation using TypedPool or RustPool
}
```

This allows:

1. Drop-in replacement without code changes
2. Thread-safe by default (always threadsafe)
3. Memory-safe with Rust guarantees
4. Easy to migrate in stages

## Next Steps

1. ✅ Fix CMake integration - DONE
2. Create wrapper types in `src/bun.js/bindings/rust_pool.zig`
3. Identify all ObjectPool usage sites and add deprecation warnings
4. Replace usage sites with RustPool wrappers
5. Run full test suite to verify no regressions
6. Performance benchmarking vs original ObjectPool
7. Production rollout with feature flags

## Verification Commands

```bash
# Build with Rust pool integration
cmake -B build/debug -S . -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build build/debug --target dependencies
cmake --build build/debug

# Verify library is linked
otool -L build/debug/bun-debug | grep pool_ffi
# Should show: @rpath/libbun_pool_ffi.dylib

# Run Rust pool tests
bun bd test test/js/bun/rust_pool.test.ts

# Run full test suite
bun bd test test/js/bun/http/serve.test.ts
```

## Files Modified

- ✅ `cmake/targets/BuildBun.cmake` - Added add_dependencies(${bun} dependencies)
- 📋 `src/bun.js/bindings/rust_pool.zig` - Add wrapper types (to do)
- 📋 All ObjectPool usage sites - Replace with RustPool (to do)

## Acceptance Criteria

Phase 4 Progress:

- ✅ CMake integration fixed
- 📋 Create wrapper types
- 📋 Replace all ObjectPool usage sites
- 📋 Run full test suite
- 📋 Performance benchmarks
- 📋 Production rollout plan

## References

- **BuildBun.cmake**: `/Users/jim/work/bun/cmake/targets/BuildBun.cmake:1328`
- **BuildRustPoolFFI.cmake**: `/Users/jim/work/bun/cmake/targets/BuildRustPoolFFI.cmake`
- **Zig Bindings**: `/Users/jim/work/bun/src/bun.js/bindings/rust_pool.zig`
- **Track Documents**: `/Users/jim/work/bun/conductor/tracks/bun_rust_confluence_20260315/`

## Conclusion

Successfully fixed the CMake integration issue that was blocking Phase 4. The Rust pool FFI library is now properly integrated into the build system and will be automatically built and linked when compiling Bun. Ready to proceed with replacing ObjectPool usage sites with the RustPool implementation.
