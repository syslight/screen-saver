from __future__ import annotations

import argparse
import asyncio
from pathlib import Path

from home_hub_connector.client import HomeHubConnector
from home_hub_connector.local_frame import LocalFrameClient
from linux_room_node.config import NodeCredentials


def default_credentials_path() -> Path:
    return Path.home() / ".local" / "share" / "family-home-agent" / "cloud-home-hub.json"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Family Home Hub cloud connector")
    parser.add_argument("--cloud", required=True)
    parser.add_argument("--credentials", type=Path, default=default_credentials_path())
    parser.add_argument("--pairing-code")
    parser.add_argument("--name", default="家庭主服务器")
    parser.add_argument("--frame-ws", default="ws://127.0.0.1:8780/ws")
    parser.add_argument("--agent", default="http://127.0.0.1:8790")
    return parser


async def run(args: argparse.Namespace) -> None:
    if args.pairing_code:
        credentials = await HomeHubConnector.pair(args.cloud, args.pairing_code, name=args.name)
        credentials.save(args.credentials)
        print(f"Home Hub paired; credentials stored securely at {args.credentials}")
    else:
        credentials = NodeCredentials.load(args.credentials)
    local = LocalFrameClient(args.frame_ws, args.agent)
    await HomeHubConnector(args.cloud, credentials, local).run_forever()


def main() -> None:
    asyncio.run(run(build_parser().parse_args()))


if __name__ == "__main__":
    main()
