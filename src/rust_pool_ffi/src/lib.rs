//! Bun Pool FFI - Thread-safe object pool for Bun
//!
//! This library provides a lock-free object pool implementation using
//! literbike's AtomicPool for maximum performance under concurrent access.
//!
//! # Safety
//!
//! All functions are thread-safe and can be called concurrently from
//! multiple threads without external synchronization.

use literbike::json::pool::AtomicPool;
use std::ffi::c_void;

/// Newtype wrapper to make raw pointers Send-safe for use in AtomicPool.
///
/// Safety: the pool only stores pointers, never dereferences them.
/// All actual dereferencing happens in Zig/C caller code under their own
/// synchronization rules.
#[derive(Clone, Copy)]
struct OpaquePtr(*mut c_void);
unsafe impl Send for OpaquePtr {}

//
// FFI API for Bun
//

/// Opaque handle to a pool
#[repr(C)]
pub struct PoolHandle {
    pool: *mut AtomicPool<OpaquePtr>,
}

// Safety: PoolHandle wraps a Box<AtomicPool<OpaquePtr>> which is Send.
unsafe impl Send for PoolHandle {}
unsafe impl Sync for PoolHandle {}

/// Create a new pool with specified max size
///
/// # Arguments
///
/// * `max_size` - Maximum number of objects to keep in the pool (0 = unlimited)
///
/// # Returns
///
/// Handle to the newly created pool, or null on error
#[no_mangle]
pub extern "C" fn bun_pool_create_max(max_size: usize) -> *mut PoolHandle {
    let pool = if max_size == 0 {
        Box::new(AtomicPool::new())
    } else {
        Box::new(AtomicPool::with_max_size(max_size))
    };
    let handle = Box::new(PoolHandle {
        pool: Box::into_raw(pool),
    });
    Box::into_raw(handle)
}

/// Create a new pool with default max size (1000)
///
/// # Returns
///
/// Handle to the newly created pool, or null on error
#[no_mangle]
pub extern "C" fn bun_pool_create() -> *mut PoolHandle {
    bun_pool_create_max(1000)
}

/// Get an object from the pool
///
/// # Arguments
///
/// * `handle` - Pool handle from bun_pool_create()
///
/// # Returns
///
/// Object pointer, or null if pool was empty (caller should create new)
#[no_mangle]
pub extern "C" fn bun_pool_get(handle: *mut PoolHandle) -> *mut c_void {
    if handle.is_null() {
        return std::ptr::null_mut();
    }

    unsafe {
        let pool = &*(*handle).pool;
        pool.get_or_create(|| OpaquePtr(std::ptr::null_mut())).0
    }
}

/// Return an object to the pool
///
/// # Arguments
///
/// * `handle` - Pool handle from bun_pool_create()
/// * `obj` - Object pointer to return (can be null, will be ignored)
#[no_mangle]
pub extern "C" fn bun_pool_put(handle: *mut PoolHandle, obj: *mut c_void) {
    if handle.is_null() || obj.is_null() {
        return;
    }

    unsafe {
        let pool = &*(*handle).pool;
        pool.put(OpaquePtr(obj));
    }
}

/// Get the number of objects in the pool
#[no_mangle]
pub extern "C" fn bun_pool_size(handle: *mut PoolHandle) -> usize {
    if handle.is_null() {
        return 0;
    }
    unsafe { (*(*handle).pool).size() }
}

/// Get the total number of objects created
#[no_mangle]
pub extern "C" fn bun_pool_total_created(handle: *mut PoolHandle) -> usize {
    if handle.is_null() {
        return 0;
    }
    unsafe { (*(*handle).pool).total_created() }
}

/// Clear all objects from the pool
#[no_mangle]
pub extern "C" fn bun_pool_clear(handle: *mut PoolHandle) {
    if handle.is_null() {
        return;
    }
    unsafe { (*(*handle).pool).clear() }
}

/// Destroy a pool and free all resources
///
/// # Safety
///
/// After calling this function, the handle becomes invalid and must not be used.
#[no_mangle]
pub extern "C" fn bun_pool_destroy(handle: *mut PoolHandle) {
    if handle.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw((*handle).pool));
        drop(Box::from_raw(handle));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pool_basic() {
        let pool: AtomicPool<OpaquePtr> = AtomicPool::new();

        // Get from empty pool returns null
        assert!(pool.get_or_create(|| OpaquePtr(std::ptr::null_mut())).0.is_null());
        assert_eq!(pool.total_created(), 1);

        // Put an object
        let obj = 0x1000 as *mut c_void;
        pool.put(OpaquePtr(obj));

        // Now get should return it
        let retrieved = pool.get_or_create(|| OpaquePtr(std::ptr::null_mut())).0;
        assert_eq!(retrieved, obj);
        assert_eq!(pool.total_created(), 1);
    }

    #[test]
    fn test_pool_multiple() {
        let pool: AtomicPool<OpaquePtr> = AtomicPool::new();

        pool.put(OpaquePtr(0x1000 as *mut c_void));
        pool.put(OpaquePtr(0x2000 as *mut c_void));
        pool.put(OpaquePtr(0x3000 as *mut c_void));

        assert_eq!(pool.size(), 3);

        let mut count = 0;
        while !pool.get_or_create(|| OpaquePtr(std::ptr::null_mut())).0.is_null() {
            count += 1;
        }
        assert_eq!(count, 3);
    }

    #[test]
    fn test_ffi_basic() {
        let handle = bun_pool_create();
        assert!(!handle.is_null());

        let obj = bun_pool_get(handle);
        assert!(obj.is_null());

        let ptr = 0x1000 as *mut c_void;
        bun_pool_put(handle, ptr);

        let retrieved = bun_pool_get(handle);
        assert_eq!(retrieved, ptr);

        bun_pool_destroy(handle);
    }

    #[test]
    fn test_ffi_multiple() {
        let handle = bun_pool_create();

        bun_pool_put(handle, 0x1000 as *mut c_void);
        bun_pool_put(handle, 0x2000 as *mut c_void);
        bun_pool_put(handle, 0x3000 as *mut c_void);

        assert_eq!(bun_pool_size(handle), 3);

        let mut count = 0;
        while !bun_pool_get(handle).is_null() {
            count += 1;
        }
        assert_eq!(count, 3);

        bun_pool_destroy(handle);
    }
}
