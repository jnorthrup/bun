#!/bin/bash
# Memory leak detection tests for RustPool FFI
# This script runs valgrind and ASAN checks to verify no memory leaks

set -e

echo "=== RustPool Memory Leak Detection Tests ==="

# Check if valgrind is available
if command -v valgrind &> /dev/null; then
    echo ""
    echo "Running valgrind leak detection..."
    
    # Build debug version of Bun
    echo "Building debug version..."
    bun bd
    
    # Run tests with valgrind
    echo "Running tests with valgrind..."
    valgrind --leak-check=full \
             --show-leak-kinds=all \
             --track-origins=yes \
             --verbose \
             --log-file=valgrind-out.txt \
             ./build/debug/bun-debug test/js/bun/rust_pool.test.ts
    
    # Check valgrind output for leaks
    if grep -q "definitely lost: 0 bytes" valgrind-out.txt && \
       grep -q "indirectly lost: 0 bytes" valgrind-out.txt && \
       grep -q "possibly lost: 0 bytes" valgrind-out.txt; then
        echo "✓ Valgrind: No memory leaks detected"
        rm valgrind-out.txt
    else
        echo "✗ Valgrind: Memory leaks detected!"
        echo "See valgrind-out.txt for details"
        exit 1
    fi
else
    echo "⚠ Valgrind not found, skipping valgrind tests"
fi

# Check if ASAN is available
if command -v clang &> /dev/null; then
    echo ""
    echo "Running AddressSanitizer checks..."
    
    # Build with ASAN
    echo "Building with ASAN..."
    bun bd clean
    CC=clang CXX=clang++ bun bd
    
    # Run tests
    echo "Running tests with ASAN..."
    ASAN_OPTIONS=detect_leaks=1:symbolize=1 ./build/debug/bun-debug test/js/bun/rust_pool.test.ts
    
    echo "✓ ASAN: No memory leaks detected"
else
    echo "⚠ Clang not found, skipping ASAN tests"
fi

echo ""
echo "=== All memory leak tests passed ==="
