#!/usr/bin/env python3
"""原传跨网中继（rendezvous relay）。

协议：连接后第一行 ASCII 命令（\\n 结尾）。
  ROOM <key>\n    拨号/等待：同 key 两端桥接。先到者保持连接等待（不读数据，
                  字节留在内核缓冲区，由桥接方直接泵送），15 分钟无对端则回收。
  BRIDGE <key>\n  监听端收到 "INCOMING <key>\\n" 后，用本命令开启第二条连接，
                  与等待中的拨号方桥接。
  LISTEN <key>\n  常驻监听：有拨号时收到 "INCOMING <key>\\n"；行内 PING 回 PONG。
  PING\n          独立保活探测，回 "PONG\\n" 即断。

安全：key 来自配对令牌或 128 位设备 id；载荷端到端加密，中继只见握手元数据与密文。
限制：房间数、每 IP 连接速率、纯数字 key（设备码）尝试速率均有上限。
"""
import asyncio
import os
import time
from collections import defaultdict, deque

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = int(os.environ.get("YUANCHUAN_RELAY_PORT", "47660"))
MAX_ROOMS = 500
ROOM_TTL = 15 * 60
MAX_CONNS_PER_IP_PER_MIN = 120
MAX_NUMERIC_ATTEMPTS_PER_MIN = 10
KEY_ALLOWED = set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:_-"
)

# key -> {"reader","writer","done":asyncio.Event,"wait_listener":bool,"created":ts}
rooms: dict[str, dict] = {}
listeners: dict[str, asyncio.StreamWriter] = {}
conn_times: defaultdict[str, deque] = defaultdict(deque)
numeric_times: defaultdict[str, deque] = defaultdict(deque)
lock = asyncio.Lock()


def valid_key(key: str) -> bool:
    return 4 <= len(key) <= 128 and set(key) <= KEY_ALLOWED


def over_rate(deq: deque, limit: int, window: float) -> bool:
    now = time.monotonic()
    while deq and now - deq[0] > window:
        deq.popleft()
    deq.append(now)
    return len(deq) > limit


async def reject(writer: asyncio.StreamWriter, message: str) -> None:
    try:
        writer.write(f"ERR {message}\n".encode("ascii"))
        await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def pump(src: asyncio.StreamReader, dst: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await src.read(65536)
            if not data:
                break
            dst.write(data)
            await dst.drain()
    except Exception:
        pass
    finally:
        try:
            dst.close()
        except Exception:
            pass


async def bridge(
    a: dict,
    b: dict,
    drop_entry: str | None = None,
) -> None:
    a["done"].set()
    b["done"].set()
    if drop_entry is not None:
        async with lock:
            if rooms.get(drop_entry) is not None:
                rooms.pop(drop_entry, None)
    await asyncio.gather(
        pump(a["reader"], b["writer"]),
        pump(b["reader"], a["writer"]),
    )
    for peer in (a, b):
        try:
            peer["writer"].close()
        except Exception:
            pass


async def hold_room(key: str, entry: dict) -> None:
    """先到一方：保持连接等待对端；绝不读 socket，数据由内核缓冲。"""
    try:
        await asyncio.wait_for(entry["done"].wait(), timeout=ROOM_TTL)
        return  # 已被桥接方接管，本任务退出（socket 归桥接任务管）。
    except asyncio.TimeoutError:
        pass
    except Exception:
        pass
    async with lock:
        if rooms.get(key) is entry:
            rooms.pop(key, None)
    try:
        entry["writer"].close()
    except Exception:
        pass


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    peer_addr = writer.get_extra_info("peername")
    ip = peer_addr[0] if peer_addr else "?"
    if over_rate(conn_times[ip], MAX_CONNS_PER_IP_PER_MIN, 60):
        await reject(writer, "RATE-LIMIT")
        return
    try:
        line = await asyncio.wait_for(reader.readline(), timeout=30)
    except asyncio.TimeoutError:
        line = b""
    if not line:
        writer.close()
        return
    try:
        parts = line.decode("ascii").strip().split(" ", 1)
    except UnicodeDecodeError:
        await reject(writer, "BAD-CMD")
        return
    if len(parts) != 2 or not valid_key(parts[1]):
        await reject(writer, "BAD-CMD")
        return
    kind, key = parts[0], parts[1]
    numeric_limited = (
        key.isdigit() and over_rate(numeric_times[ip], MAX_NUMERIC_ATTEMPTS_PER_MIN, 60)
    )

    if kind == "PING":
        writer.write(b"PONG\n")
        await writer.drain()
        writer.close()
        return

    if kind == "LISTEN":
        if numeric_limited:
            await reject(writer, "RATE-LIMIT")
            return
        old = listeners.get(key)
        if old is not None:
            try:
                old.close()
            except Exception:
                pass
        listeners[key] = writer
        try:
            while True:
                data = await reader.readline()
                if not data:
                    break
                if data.strip() == b"PING":
                    writer.write(b"PONG\n")
                    await writer.drain()
        except Exception:
            pass
        finally:
            if listeners.get(key) is writer:
                listeners.pop(key, None)
            try:
                writer.close()
            except Exception:
                pass
        return

    if kind == "ROOM":
        if numeric_limited:
            await reject(writer, "RATE-LIMIT")
            return
        me = {"reader": reader, "writer": writer, "done": asyncio.Event()}
        role = "holder"
        entry = None
        async with lock:
            existing = rooms.get(key)
            if existing is None:
                if len(rooms) >= MAX_ROOMS:
                    role = "reject"
                else:
                    wait_listener = key in listeners
                    entry = {
                        "reader": reader,
                        "writer": writer,
                        "done": me["done"],
                        "wait_listener": wait_listener,
                        "created": time.monotonic(),
                    }
                    rooms[key] = entry
                    role = "holder"
            elif existing.get("wait_listener"):
                role = "reject"
            else:
                role = "second"
                entry = existing
                rooms.pop(key, None)
        if role == "reject":
            await reject(writer, "ROOM-TAKEN")
            return
        if role == "holder":
            if entry["wait_listener"]:
                listener = listeners.get(key)
                if listener is None:
                    async with lock:
                        if rooms.get(key) is entry:
                            rooms.pop(key, None)
                    await reject(writer, "NO-LISTENER")
                    return
                try:
                    listener.write(f"INCOMING {key}\n".encode("ascii"))
                    await listener.drain()
                except Exception:
                    async with lock:
                        if rooms.get(key) is entry:
                            rooms.pop(key, None)
                    listeners.pop(key, None)
                    await reject(writer, "NO-LISTENER")
                    return
            await hold_room(key, entry)
            return
        # second：与先到者桥接。
        first = entry
        await bridge(first, me)
        return

    if kind == "BRIDGE":
        if numeric_limited:
            await reject(writer, "RATE-LIMIT")
            return
        me = {"reader": reader, "writer": writer, "done": asyncio.Event()}
        async with lock:
            entry = rooms.get(key) if rooms.get(key, {}).get("wait_listener") else None
            if entry is not None:
                rooms.pop(key, None)
        if entry is None:
            await reject(writer, "NO-PENDING")
            return
        await bridge(entry, me)
        return

    await reject(writer, "BAD-CMD")


async def sweeper() -> None:
    while True:
        await asyncio.sleep(60)
        now = time.monotonic()
        async with lock:
            stale = [
                k for k, v in rooms.items() if now - v["created"] > ROOM_TTL
            ]
            for k in stale:
                rooms.pop(k, None)


async def main() -> None:
    server = await asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT)
    asyncio.create_task(sweeper())
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
