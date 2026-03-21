## Investigation from Bun Runtime - Related Memory Leak Analysis

We investigated similar memory leak patterns in Bun runtime (which also uses WebKit JavaScriptCore) and found this issue through our research.

### Our Findings

We identified **4 unique JSC GC memory leaks** in our runtime with similar characteristics:
- `JSC::SlotVisitor::drainFromShared` race condition (7,214 stack frames)
- `WTF::HashTable::removeIterator` (7,214 frames)
- `WTF::Vector<JSC::InByVariant>::operator=` (7,220 frames)
- `JSC::ASTBuilder::createForOfLoop` (713 frames)

### Root Cause Pattern

Your analysis of sidebar prefetch loading full tool outputs aligns with our findings - **WebKit JSC GC is not properly reclaiming memory during parallel marking phase**. This appears to be an upstream WebKit issue affecting all embedders.

### Related Upstream Issues
- WPEWebKit #1622: https://github.com/WebPlatformForEmbedded/WPEWebKit/issues/1622
- WebKit #200863: https://bugs.webkit.org/show_bug.cgi?id=200863
- LLVM #115992: https://github.com/llvm/llvm-project/issues/115992

### Tool We Built

We created an ASAN tracker (test/asan_tracker.zig) that can help identify and classify these leaks. Happy to share if useful for your investigation.

### Bun Tracking Issue
- https://github.com/oven-sh/bun/issues/28343

**This is a cross-project WebKit GC issue - coordinating across Bun, Claude Code, and other embedders.**
