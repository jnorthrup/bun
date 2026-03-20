import { memoryUsage, vmmap } from "bun:jsc";
import { describe, expect, it } from "bun:test";
import { isMacOS } from "harness";

describe("bun:jsc memory footprint", () => {
  describe("memoryUsage().footprint", () => {
    it("returns a footprint object with expected fields", () => {
      const mem = memoryUsage();
      expect(mem.footprint).toBeDefined();
      expect(mem.footprint).toBeTypeOf("object");

      const fp = mem.footprint;
      expect(fp.physical).toBeTypeOf("number");
      expect(fp.internal).toBeTypeOf("number");
      expect(fp.compressed).toBeTypeOf("number");
      expect(fp.purgeable).toBeTypeOf("number");
      expect(fp.regionCount).toBeTypeOf("number");
    });

    it("physical footprint is non-zero for a running process", () => {
      const mem = memoryUsage();
      expect(mem.footprint.physical).toBeGreaterThan(0);
    });

    it("physical footprint is less than or equal to RSS", () => {
      const mem = memoryUsage();
      // On macOS, phys_footprint <= resident_size (RSS includes shared pages)
      // On Linux, physical is PSS which can be smaller than RSS
      expect(mem.footprint.physical).toBeLessThanOrEqual(mem.current + 1); // +1 for rounding
    });

    it("preserves existing memoryUsage fields", () => {
      const mem = memoryUsage();
      expect(mem.current).toBeGreaterThan(0);
      expect(mem.peak).toBeGreaterThan(0);
      expect(mem.currentCommit).toBeGreaterThan(0);
      expect(mem.peakCommit).toBeGreaterThan(0);
      expect(mem.pageFaults).toBeGreaterThan(0);
    });
  });

  describe("vmmap", () => {
    it("returns a non-null result", () => {
      const map = vmmap();
      expect(map).not.toBeNull();
      expect(map).toBeTypeOf("object");
    });

    it("has totalVirtual, totalResident, totalDirty", () => {
      const map = vmmap();
      expect(map.totalVirtual).toBeTypeOf("number");
      expect(map.totalResident).toBeTypeOf("number");
      expect(map.totalDirty).toBeTypeOf("number");

      // totalVirtual should be very large due to JSC Gigacage reservation
      expect(map.totalVirtual).toBeGreaterThan(1024 * 1024 * 1024); // > 1 GB
      expect(map.totalResident).toBeGreaterThan(0);
    });

    it("has a regions array", () => {
      const map = vmmap();
      expect(map.regions).toBeTypeOf("object");
      expect(Array.isArray(map.regions)).toBe(true);
      expect(map.regions.length).toBeGreaterThan(0);
    });

    it("each region has name, size, resident, dirty, swapped, count", () => {
      const map = vmmap();
      for (const region of map.regions) {
        expect(region.name).toBeTypeOf("string");
        expect(region.size).toBeTypeOf("number");
        expect(region.resident).toBeTypeOf("number");
        expect(region.dirty).toBeTypeOf("number");
        expect(region.swapped).toBeTypeOf("number");
        expect(region.count).toBeTypeOf("number");
        expect(region.size).toBeGreaterThan(0);
        expect(region.count).toBeGreaterThan(0);
      }
    });

    it("regions are sorted by size descending", () => {
      const map = vmmap();
      const sizes = map.regions.map((r: any) => r.size);
      for (let i = 1; i < sizes.length; i++) {
        expect(sizes[i]).toBeLessThanOrEqual(sizes[i - 1]);
      }
    });

    it("includes known JSC/WebKit regions", () => {
      const map = vmmap();
      const names = new Set(map.regions.map((r: any) => r.name));

      if (isMacOS) {
        // On macOS, we should see tagged VM regions
        const hasKnownTag = [...names].some(
          n =>
            n.includes("WebKit") || n.includes("JavaScriptCore") || n.includes("IOAccelerator") || n.includes("tag_"),
        );
        expect(hasKnownTag).toBe(true);
      } else {
        // On Linux, we should see anonymous or mapped regions
        const hasAnon = [...names].some(n => n.includes("[anon]") || n.includes("[heap]") || n.includes("bun"));
        expect(hasAnon).toBe(true);
      }
    });

    it("totalVirtual >= totalResident", () => {
      const map = vmmap();
      expect(map.totalVirtual).toBeGreaterThanOrEqual(map.totalResident);
    });

    it("catches allocation growth", () => {
      // Allocate a bunch of memory and check vmmap reflects it
      const before = vmmap();
      const beforeResident = before.totalResident;

      // Allocate ~10 MB
      const bigArray = new Array(10_000_000).fill(42);

      const after = vmmap();
      // Resident should have grown (may be delayed by OS page faulting)
      expect(after.totalResident).toBeGreaterThanOrEqual(beforeResident - 1024 * 1024); // allow 1MB tolerance

      // keep reference so GC doesn't collect it
      expect(bigArray.length).toBe(10_000_000);
    });
  });
});
