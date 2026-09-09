"""Bridge Neovim's JSONL connection to the shared local Codex daemon.

The terminal clients use `--remote unix://` to join the same daemon. This
process owns only an observer connection; exiting never stops agent work.
"""

import asyncio
import os
import sys
from pathlib import Path

from websockets.legacy.client import unix_connect


async def start_server():
    process = await asyncio.create_subprocess_exec(
        "systemctl", "--user", "start", "codex-app-server.service",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    try:
        _, stderr = await asyncio.wait_for(process.communicate(), 50)
    except BaseException:
        if process.returncode is None:
            process.kill()
            await process.wait()
        raise
    if process.returncode:
        raise RuntimeError(stderr.decode().strip() or "Could not start Codex app-server service")


def server_connection():
    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    socket_path = codex_home / "app-server-control" / "app-server-control.sock"
    # Match Codex's Unix-socket handshake, without compression negotiation.
    return unix_connect(
        str(socket_path), uri="ws://localhost/", compression=None,
        max_size=64 * 1024 * 1024, open_timeout=1,
    )


async def wait_ready():
    async def probe():
        while True:
            try:
                async with server_connection():
                    return
            except (OSError, asyncio.TimeoutError):
                await asyncio.sleep(0.1)

    await asyncio.wait_for(probe(), 30)


async def connect():
    await start_server()

    reader = asyncio.StreamReader(limit=64 * 1024 * 1024)
    transport, _ = await asyncio.get_running_loop().connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer,
    )
    try:
        async with server_connection() as websocket:
            async def send():
                while line := await reader.readline():
                    await websocket.send(line.decode().rstrip("\n"))

            async def receive():
                async for message in websocket:
                    sys.stdout.write(message + "\n")
                    sys.stdout.flush()

            tasks = [asyncio.create_task(send()), asyncio.create_task(receive())]
            try:
                done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                for task in done:
                    task.result()
            finally:
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
    finally:
        transport.close()


if __name__ == "__main__":
    try:
        asyncio.run(wait_ready() if sys.argv[1:] == ["--wait"] else connect())
    except (Exception, KeyboardInterrupt) as error:
        print(str(error) or "Timed out waiting for the Codex app-server service", file=sys.stderr)
        sys.exit(1)
