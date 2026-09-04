"""Bridge Neovim's JSONL connection to the shared local Codex daemon.

The terminal clients use `--remote unix://` to join the same daemon. This
process owns only an observer connection; exiting never stops agent work.
"""

import asyncio
import json
import sys

from websockets.legacy.client import unix_connect


async def connect(command):
    process = await asyncio.create_subprocess_exec(
        *command, "app-server", "daemon", "start",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(), 30)
    except BaseException:
        if process.returncode is None:
            process.kill()
            await process.wait()
        raise
    if process.returncode:
        raise RuntimeError(stderr.decode().strip() or "Could not start Codex daemon")
    socket_path = json.loads(stdout)["socketPath"]

    reader = asyncio.StreamReader(limit=64 * 1024 * 1024)
    transport, _ = await asyncio.get_running_loop().connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer,
    )
    try:
        # Match Codex's Unix-socket handshake, without compression negotiation.
        async with unix_connect(
            socket_path, uri="ws://localhost/", compression=None,
            max_size=64 * 1024 * 1024, open_timeout=10,
        ) as websocket:
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
        asyncio.run(connect(sys.argv[1:] or ["codexvenv"]))
    except (Exception, KeyboardInterrupt) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
