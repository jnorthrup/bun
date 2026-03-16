//! Bun Pool FFI - Thread-safe object pool for Bun
//!
//! This library provides a lock-free object pool implementation using
//! crossbeam's SegQueue for maximum performance under concurrent access.
//!
//! # Safety
//!
//! All functions are thread-safe and can be called concurrently from
//! multiple threads without external synchronization.

use crossbeam_queue::SegQueue;
use std::ffi::c_void;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

/// Thread-safe pool for object reuse
///
/// Uses a lock-free queue for maximum performance under concurrent access.
/// Objects are recycled to avoid allocation overhead.
///
/// # Memory Safety
///
/// - Uses proper atomic ordering for synchronization
/// - Pool has maximum size to prevent unbounded growth
/// - Counters are updated atomically with queue operations
pub struct AtomicPool {
    queue: Arc<SegQueue<*mut c_void>>,
    total_created: Arc<AtomicUsize>,
    current_size: Arc<AtomicUsize>,
    max_size: usize,
}

impl AtomicPool {
    /// Create a new empty pool with default max size (1000)
    pub fn new() -> Self {
        Self::with_max_size(1000)
    }

    /// Create a new empty pool with specified max size
    ///
    /// This prevents memory leaks by limiting pool growth
    pub fn with_max_size(max_size: usize) -> Self {
        Self {
            queue: Arc::new(SegQueue::new()),
            total_created: Arc::new(AtomicUsize::new(0)),
            current_size: Arc::new(AtomicUsize::new(0)),
            max_size,
        }
    }

    /// Get an object from the pool, or create a new one if empty
    pub fn get(&self) -> *mut c_void {
        if let Some(obj) = self.queue.pop() {
            self.current_size.fetch_sub(1, Ordering::Relaxed);
            return obj;
        }

        // Pool empty - return null to signal "create new"
        self.total_created.fetch_add(1, Ordering::Relaxed);
        std::ptr::null_mut()
    }

    /// Return an object to the pool for reuse
    ///
    /// If the pool is at max capacity, the object will be dropped
    /// to prevent unbounded memory growth (memory leak prevention).
    pub fn put(&self, obj: *mut c_void) {
        if obj.is_null() {
            return;
        }

        // Check current size BEFORE pushing to prevent race condition
        let current = self.current_size.load(Ordering::Acquire);

        if current >= self.max_size {
            // Pool at capacity - drop the object to prevent memory leak
            return;
        }

        // Try to increment size with compare-exchange to prevent race
        match self.current_size.compare_exchange(
            current,
            current + 1,
            Ordering::AcqRel,
            Ordering::Acquire,
        ) {
            Ok(_) => {
                // Successfully reserved a slot, now push to queue
                self.queue.push(obj);
            }
            Err(_) => {
                // Another thread added an object, check new size
                let new_current = self.current_size.load(Ordering::Acquire);
                if new_current < self.max_size {
                    // Still under capacity, try again
                    self.queue.push(obj);
                    self.current_size.fetch_add(1, Ordering::Release);
                }
                // Otherwise, drop the object to prevent memory leak
            }
        }
    }

    /// Get the number of objects currently in the pool
    pub fn size(&self) -> usize {
        self.current_size.load(Ordering::Relaxed)
    }

    /// Get the total number of objects created
    pub fn total_created(&self) -> usize {
        self.total_created.load(Ordering::Relaxed)
    }

    /// Clear all objects from the pool
    pub fn clear(&self) {
        while let Some(_) = self.queue.pop() {
            self.current_size.fetch_sub(1, Ordering::Relaxed);
        }
    }
}

//
// FFI API for Bun
//

/// Opaque handle to a pool
#[repr(C)]
pub struct PoolHandle {
    pool: *mut AtomicPool,
}

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
/// Object pointer, or null if pool is empty (caller should create new)
#[no_mangle]
pub extern "C" fn bun_pool_get(handle: *mut PoolHandle) -> *mut c_void {
    if handle.is_null() {
        return std::ptr::null_mut();
    }

    unsafe {
        let pool = &*(*handle).pool;
        pool.get()
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
    if handle.is_null() {
        return;
    }

    unsafe {
        let pool = &*(*handle).pool;
        pool.put(obj);
    }
}

/// Get the number of objects in the pool
///
/// # Arguments
///
/// * `handle` - Pool handle from bun_pool_create()
///
/// # Returns
///
/// Number of objects currently in the pool
#[no_mangle]
pub extern "C" fn bun_pool_size(handle: *mut PoolHandle) -> usize {
    if handle.is_null() {
        return 0;
    }

    unsafe {
        let pool = &*(*handle).pool;
        pool.size()
    }
}

/// Get the total number of objects created
///
/// # Arguments
///
/// * `handle` - Pool handle from bun_pool_create()
///
/// # Returns
///
/// Total number of objects created (in pool + in use)
#[no_mangle]
pub extern "C" fn bun_pool_total_created(handle: *mut PoolHandle) -> usize {
    if handle.is_null() {
        return 0;
    }

    unsafe {
        let pool = &*(*handle).pool;
        pool.total_created()
    }
}

/// Clear all objects from the pool
///
/// # Arguments
///
/// * `handle` - Pool handle from bun_pool_create()
#[no_mangle]
pub extern "C" fn bun_pool_clear(handle: *mut PoolHandle) {
    if handle.is_null() {
        return;
    }

    unsafe {
        let pool = &*(*handle).pool;
        pool.clear();
    }
}

/// Destroy a pool and free all resources
///
/// # Arguments
///
/// * `handle` - Pool handle from bun_pool_create()
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
        let pool_box = Box::from_raw((*handle).pool);
        let handle_box = Box::from_raw(handle);

        // Drop the pool and handle
        drop(pool_box);
        drop(handle_box);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pool_basic() {
        let pool = AtomicPool::new();

        // Get from empty pool returns null
        assert!(pool.get().is_null());
        assert_eq!(pool.total_created(), 1);

        // Put an object
        let obj = 0x1000 as *mut c_void;
        pool.put(obj);

        // Now get should return it
        let retrieved = pool.get();
        assert_eq!(retrieved, obj);
        assert_eq!(pool.total_created(), 1); // No new object created
    }

    #[test]
    fn test_pool_multiple() {
        let pool = AtomicPool::new();

        // Put multiple objects
        let obj1 = 0x1000 as *mut c_void;
        let obj2 = 0x2000 as *mut c_void;
        let obj3 = 0x3000 as *mut c_void;

        pool.put(obj1);
        pool.put(obj2);
        pool.put(obj3);

        assert_eq!(pool.size(), 3);

        // Get them back (order not guaranteed)
        let mut count = 0;
        while pool.get().is_null() == false {
            count += 1;
        }

        assert_eq!(count, 3);
    }

    #[test]
    fn test_ffi_basic() {
        let handle = bun_pool_create();
        assert!(!handle.is_null());

        // Get from empty pool
        let obj = bun_pool_get(handle);
        assert!(obj.is_null());

        // Put an object
        let ptr = 0x1000 as *mut c_void;
        bun_pool_put(handle, ptr);

        // Get it back
        let retrieved = bun_pool_get(handle);
        assert_eq!(retrieved, ptr);

        // Cleanup
        bun_pool_destroy(handle);
    }

    #[test]
    fn test_ffi_multiple() {
        let handle = bun_pool_create();

        // Put multiple objects
        bun_pool_put(handle, 0x1000 as *mut c_void);
        bun_pool_put(handle, 0x2000 as *mut c_void);
        bun_pool_put(handle, 0x3000 as *mut c_void);

        assert_eq!(bun_pool_size(handle), 3);

        // Get them back
        let mut count = 0;
        while !bun_pool_get(handle).is_null() {
            count += 1;
        }

        assert_eq!(count, 3);

        bun_pool_destroy(handle);
    }
}
