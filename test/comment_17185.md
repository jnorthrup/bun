## Related: Bus Subscription Memory Leak Pattern

We identified a similar **Bus subscription leak pattern** in our investigation of WebKit-based runtimes.

### Our Finding

In Bun runtime, we found that **event subscriptions created but never unsubscribed** hold references to closures, preventing GC. This matches your fix in src/bus/index.ts.

### Related Leaks Found

We identified 4 JSC GC leaks total:
1. HashTable iterator invalidation during GC
2. Vector assignment during parallel marking
3. SlotVisitor::drainFromShared race condition
4. AST node leaks (for-of destructuring)

### Cross-Project Coordination

This appears to be a **WebKit JavaScriptCore upstream issue** affecting multiple projects:
- anomalyco/opencode (this issue)
- Bun (our runtime)
- Claude Code
- Safari
- React Native

### Upstream References
- WPEWebKit #1622: https://github.com/WebPlatformForEmbedded/WPEWebKit/issues/1622
- WebKit #200863: https://bugs.webkit.org/show_bug.cgi?id=200863

**Would your Bus subscription fix help other embedders? Consider upstreaming to WebKit.**
