import { describe, expect, test } from "bun:test";
import { bunEnv, bunExe } from "harness";
import { once } from "node:events";
import { WebSocket } from "ws";

function createUpgradeServer() {
  return Bun.serve({
    port: 0,
    fetch(req, server) {
      if (
        server.upgrade(req, {
          headers: {
            "X-Upgrade-Test": "upgrade-response",
            "X-Multi": "first",
            "x-multi": "second",
          },
        })
      ) {
        return;
      }
      return new Response("Expected websocket upgrade", { status: 400 });
    },
    websocket: {
      message() {},
    },
  });
}

function createRejectingServer(statusCode = 400) {
  return Bun.serve({
    port: 0,
    fetch() {
      return new Response("Nope", {
        status: statusCode,
        headers: {
          "X-Reject-Test": "rejected",
          "Set-Cookie": "a=1",
          "set-cookie": "b=2",
        },
      });
    },
  });
}

describe("ws 'upgrade' event", () => {
  test("is emitted before 'open' with response object", async () => {
    await using server = createUpgradeServer();
    const ws = new WebSocket(`ws://127.0.0.1:${server.port}`);
    const events: string[] = [];
    let upgradeResponse: any;

    const { promise, resolve, reject } = Promise.withResolvers<void>();
    ws.on("upgrade", response => {
      events.push("upgrade");
      upgradeResponse = response;
    });
    ws.on("open", () => {
      events.push("open");
      ws.close();
    });
    ws.on("close", resolve);
    ws.on("error", reject);
    await promise;

    expect(events).toEqual(["upgrade", "open"]);
    expect(upgradeResponse.statusCode).toBe(101);
    expect(upgradeResponse.statusMessage).toBe("Switching Protocols");
    expect(upgradeResponse.headers["x-upgrade-test"]).toBe("upgrade-response");
  });

  test("'open' event receives no arguments when upgrade listener is present", async () => {
    await using server = createUpgradeServer();
    const ws = new WebSocket(`ws://127.0.0.1:${server.port}`);

    ws.on("upgrade", () => {});
    const openArgs = await once(ws, "open");
    expect(openArgs).toEqual([]);

    ws.close();
    await once(ws, "close");
  });

  test("is not emitted when no upgrade listener is registered", async () => {
    await using server = createUpgradeServer();
    const ws = new WebSocket(`ws://127.0.0.1:${server.port}`);

    const { promise, resolve, reject } = Promise.withResolvers<void>();
    ws.on("open", () => {
      ws.close();
      resolve();
    });
    ws.on("error", reject);
    await promise;
  });

  test("response headers merge duplicate values with comma", async () => {
    await using server = createUpgradeServer();
    const ws = new WebSocket(`ws://127.0.0.1:${server.port}`);

    const { promise, resolve, reject } = Promise.withResolvers<any>();
    ws.on("upgrade", resolve);
    ws.on("open", () => ws.close());
    ws.on("error", reject);
    const response = await promise;

    expect(response.headers["x-multi"]).toBe("first, second");
  });

  test("does not emit warning when registering upgrade listener", async () => {
    await using server = createUpgradeServer();

    await using proc = Bun.spawn({
      cmd: [
        bunExe(),
        "-e",
        `import WebSocket from "ws";
        const ws = new WebSocket("ws://127.0.0.1:${server.port}");
        ws.on("upgrade", () => {});
        ws.on("open", () => ws.close());
        ws.on("close", () => process.exit(0));
        ws.on("error", err => { console.error(err.message); process.exit(1); });`,
      ],
      env: bunEnv,
      stdout: "pipe",
      stderr: "pipe",
    });

    const [stdout, stderr, exitCode] = await Promise.all([proc.stdout.text(), proc.stderr.text(), proc.exited]);
    expect(stdout).toBe("");
    expect(stderr).not.toContain("'upgrade' event is not implemented");
    expect(exitCode).toBe(0);
  });
});

describe("ws 'unexpected-response' event", () => {
  test("is emitted with request and response objects on non-101 status", async () => {
    await using server = createRejectingServer(403);
    const ws = new WebSocket(`ws://127.0.0.1:${server.port}/foo?bar=1`);
    let capturedRequest: any;
    let capturedResponse: any;
    let errorEmitted = false;

    const { promise, resolve, reject } = Promise.withResolvers<void>();
    ws.on("unexpected-response", (request, response) => {
      capturedRequest = request;
      capturedResponse = response;
    });
    ws.on("error", () => {
      errorEmitted = true;
    });
    ws.on("open", () => reject(new Error("Unexpected open event")));
    ws.on("close", resolve);
    await promise;

    expect(capturedResponse.statusCode).toBe(403);
    expect(capturedResponse.statusMessage).toBe("Forbidden");
    expect(capturedResponse.headers["x-reject-test"]).toBe("rejected");
    expect(capturedRequest.method).toBe("GET");
    expect(capturedRequest.path).toBe("/foo?bar=1");
    // error should be suppressed when unexpected-response is handled
    expect(errorEmitted).toBe(false);
  });

  test("set-cookie headers are collected into an array", async () => {
    await using server = createRejectingServer(400);
    const ws = new WebSocket(`ws://127.0.0.1:${server.port}`);

    const { promise, resolve, reject } = Promise.withResolvers<any>();
    ws.on("unexpected-response", (_req, response) => resolve(response));
    ws.on("open", () => reject(new Error("Unexpected open event")));
    const response = await promise;

    expect(response.headers["set-cookie"]).toEqual(["a=1", "b=2"]);
  });

  test("emits 'error' when no unexpected-response listener is registered", async () => {
    await using server = createRejectingServer(500);
    const ws = new WebSocket(`ws://127.0.0.1:${server.port}`);

    const { promise, resolve } = Promise.withResolvers<any>();
    ws.on("error", resolve);
    const err = await promise;

    expect(err).toBeDefined();
    expect(err.message).toContain("Expected 101 status code");
  });

  test("does not emit warning when registering unexpected-response listener", async () => {
    await using server = createRejectingServer(400);

    await using proc = Bun.spawn({
      cmd: [
        bunExe(),
        "-e",
        `import WebSocket from "ws";
        const ws = new WebSocket("ws://127.0.0.1:${server.port}");
        ws.on("unexpected-response", (_req, res) => {
          console.log("status:" + res.statusCode);
        });
        ws.on("close", () => process.exit(0));
        ws.on("error", err => { console.error(err.message); process.exit(1); });`,
      ],
      env: bunEnv,
      stdout: "pipe",
      stderr: "pipe",
    });

    const [stdout, stderr, exitCode] = await Promise.all([proc.stdout.text(), proc.stderr.text(), proc.exited]);
    expect(stderr).not.toContain("'unexpected-response' event is not implemented");
    expect(stdout).toContain("status:400");
    expect(exitCode).toBe(0);
  });

  test("emits 'error' for non-handshake failures even with unexpected-response listener", async () => {
    // Connecting to a closed port should produce a connection error, not a handshake response,
    // so 'unexpected-response' should not fire and 'error' should fire instead.
    const ws = new WebSocket(`ws://127.0.0.1:1`);
    let unexpectedResponseEmitted = false;
    let errorEmitted = false;

    const { promise, resolve } = Promise.withResolvers<void>();
    ws.on("unexpected-response", () => {
      unexpectedResponseEmitted = true;
    });
    ws.on("error", () => {
      errorEmitted = true;
    });
    ws.on("close", resolve);
    await promise;

    expect(unexpectedResponseEmitted).toBe(false);
    expect(errorEmitted).toBe(true);
  });
});
