#!/usr/bin/env python3
"""Sync nginx_proxy_custom with the official Home Assistant nginx_proxy app.

The custom addon is only a thin wrapper: it uses the official image (and
therefore the official nginx template, scripts and options) and only changes
metadata plus the exposed ports. Everything else is taken from upstream.

Usage: python3 scripts/sync_nginx_proxy.py
"""

from pathlib import Path
import urllib.request

import yaml

UPSTREAM = "https://raw.githubusercontent.com/home-assistant/apps/master/nginx_proxy"
TARGET = Path(__file__).resolve().parent.parent / "nginx_proxy_custom"

# --- Local overrides --------------------------------------------------------
METADATA = {
    "slug": "nginx_proxy_custom",
    "name": "Custom NGINX Home Assistant SSL proxy",
    "url": "https://github.com/YannicNoe/ha_addons_custom/tree/main/nginx_proxy_custom",
}
# Extra ports (added on top of upstream). 80/tcp stays unmapped (null) by
# default, so the acme.sh addon (host network, standalone) can bind port 80.
EXTRA_PORTS = {"444/tcp": 444}
FORCED_PORTS = {"80/tcp": None}
EXTRA_PORT_DESCRIPTIONS = {
    "444/tcp": "Additional HTTPS port (e.g. for PROXY protocol via customize config)",
}

COPY_AS_IS = ["DOCS.md", "README.md", "CHANGELOG.md", "icon.png", "logo.png"]


def fetch(path: str) -> bytes:
    with urllib.request.urlopen(f"{UPSTREAM}/{path}", timeout=30) as resp:
        return resp.read()


def dump(data: dict) -> str:
    return "---\n" + yaml.safe_dump(
        data, sort_keys=False, allow_unicode=True, width=1000
    )


def main() -> None:
    for name in COPY_AS_IS:
        (TARGET / name).write_bytes(fetch(name))

    config = yaml.safe_load(fetch("config.yaml"))
    config.update(METADATA)
    config["ports"] = {**config.get("ports", {}), **EXTRA_PORTS, **FORCED_PORTS}
    (TARGET / "config.yaml").write_text(dump(config), encoding="utf-8")

    translations = yaml.safe_load(fetch("translations/en.yaml"))
    translations.setdefault("network", {}).update(EXTRA_PORT_DESCRIPTIONS)
    (TARGET / "translations").mkdir(exist_ok=True)
    (TARGET / "translations" / "en.yaml").write_text(
        dump(translations), encoding="utf-8"
    )

    print(f"Synced nginx_proxy_custom to upstream version {config['version']}")


if __name__ == "__main__":
    main()
