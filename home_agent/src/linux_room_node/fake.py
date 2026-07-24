from __future__ import annotations

import argparse
import asyncio
from pathlib import Path

from linux_room_node.client import FakeRoomNodeClient
from linux_room_node.config import NodeCredentials, default_credentials_path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Family Home Agent fake room node")
    parser.add_argument("--server", default="http://127.0.0.1:8790")
    parser.add_argument("--credentials", type=Path, default=default_credentials_path())
    parser.add_argument("--pairing-code")
    parser.add_argument("--name", default="客厅假节点")
    return parser


async def run(args: argparse.Namespace) -> None:
    credentials: NodeCredentials
    if args.pairing_code:
        credentials = await FakeRoomNodeClient.pair(args.server, args.pairing_code, name=args.name)
        credentials.save(args.credentials)
        print(f"Node paired; credentials stored securely at {args.credentials}")
    else:
        credentials = NodeCredentials.load(args.credentials)
    await FakeRoomNodeClient(args.server, credentials).run_forever()


def main() -> None:
    asyncio.run(run(build_parser().parse_args()))


if __name__ == "__main__":
    main()
