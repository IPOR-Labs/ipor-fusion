// Ephemeral local fork used for simulation.
//
// Anvil forks the configured provider at a pinned block and lives only for the
// duration of one command. Nothing here can reach a public network: the caller
// is impersonated on the fork, funded on the fork, and the process is killed
// afterwards.

import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { ChainError, rpc } from "./chain.mjs";

async function freePort() {
    return new Promise((done, reject) => {
        const server = createServer();
        server.on("error", reject);
        server.listen(0, "127.0.0.1", () => {
            const { port } = server.address();
            server.close(() => done(port));
        });
    });
}

/// Starts anvil forking `url` at `blockNumber` and resolves once it answers.
/// The returned handle must be stopped by the caller.
export async function startFork({ url, blockNumber, chainId, timeoutMs = 120_000 }) {
    const port = await freePort();
    const child = spawn(
        "anvil",
        [
            "--fork-url",
            url,
            "--fork-block-number",
            String(blockNumber),
            "--port",
            String(port),
            "--host",
            "127.0.0.1",
            "--silent",
        ],
        { stdio: ["ignore", "ignore", "pipe"] },
    );
    let stderr = "";
    child.stderr.on("data", (chunk) => (stderr += chunk));

    const forkUrl = `http://127.0.0.1:${port}`;
    const stop = () => {
        if (!child.killed) child.kill("SIGKILL");
    };
    process.on("exit", stop);

    const deadline = Date.now() + timeoutMs;
    for (;;) {
        if (child.exitCode !== null) {
            // Anvil's own message may contain the provider URL, so it is not reported.
            throw new ChainError("FORK_UNAVAILABLE", `anvil exited with code ${child.exitCode}`);
        }
        const answer = await rpc(forkUrl, "eth_chainId", []);
        if (!answer.error && typeof answer.result === "string") {
            const observed = Number.parseInt(answer.result, 16);
            if (chainId !== undefined && observed !== chainId) {
                stop();
                throw new ChainError("CHAIN_MISMATCH", `fork reports chain ${observed}, expected ${chainId}`);
            }
            return { url: forkUrl, stop, stderr: () => stderr };
        }
        if (Date.now() > deadline) {
            stop();
            throw new ChainError("FORK_UNAVAILABLE", "anvil did not become ready in time");
        }
        await new Promise((wait) => setTimeout(wait, 250));
    }
}

export async function forkRpc(url, method, params, code = "FORK_UNAVAILABLE") {
    const answer = await rpc(url, method, params);
    if (answer.error) throw new ChainError(code, `${method} failed on the fork`);
    return answer.result;
}
