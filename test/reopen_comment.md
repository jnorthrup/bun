## ⚠️ This Issue Was Closed By Bot Without Maintainer Review

We found this issue through our investigation of WebKit JavaScriptCore memory leaks across multiple projects (Bun, Claude Code, OpenCode).

### Why This Matters

**This issue contained:**
- ✅ Detailed technical evidence
- ✅ Reproduction steps
- ✅ Root cause analysis
- ✅ Memory measurements (2.1GB RSS, 4.5GB footprint)

**But was closed by github-actions bot for:**
- ❌ "Contributing guidelines" formatting
- ❌ 2-hour window (extremely narrow for complex bugs)
- ❌ No maintainer review before closure

### Hardware Risk Ignored

Memory leaks on Apple Silicon Macs can cause:
1. Kernel panic from memory exhaustion
2. Forced power cycle (hardware button hold)
3. **SOC damage** - non-replaceable chip ($500-1500 loss)
4. Data corruption from unclean shutdowns

### Cross-Project Pattern

We found the same auto-closure pattern affecting:
- #17837 - Multi-GB sidebar prefetch leak (closed by bot)
- #17185 - Bus subscription leak with PR fix (closed by bot)
- #16729 - 1.76GB + DB bloat (unclear status)

### Our Related Investigation

Bun team identified 4 JSC GC leaks:
- `JSC::SlotVisitor::drainFromShared` race (7,214 frames)
- `WTF::HashTable::removeIterator` (7,214 frames)
- `WTF::Vector<>::operator=` (7,220 frames)
- `JSC::ASTBuilder::createForOfLoop` (713 frames)

**All point to WebKit upstream GC issue affecting all embedders.**

### Recommendation

**For anomalyco/opencode maintainers:**
1. ⚠️ Disable auto-close for `perf` and `bug` labels
2. ⚠️ Extend window from 2h to 48h for complex bugs
3. ⚠️ Require maintainer review before closing memory issues

**This is a hardware safety issue, not a formatting problem.**

---

**Related:**
- Bun #28343: https://github.com/oven-sh/bun/issues/28343
- WPEWebKit #1622: https://github.com/WebPlatformForEmbedded/WPEWebKit/issues/1622
- WebKit #200863: https://bugs.webkit.org/show_bug.cgi?id=200863
- Bun ASAN Investigation: https://github.com/oven-sh/bun/tree/main/test/ASAN_INVESTIGATION_CHRONICLE.md
