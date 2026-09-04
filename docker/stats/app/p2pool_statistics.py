#!/usr/bin/env python3
import json
import logging
import os
import re
import socket
import traceback
import urllib.parse
import urllib.request
import urllib.error
from datetime import datetime
from typing import Optional, Tuple

import humanfriendly
from flask import Flask, abort, render_template
from prefixed import Float

# ----------------------------
# Logging
# ----------------------------
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

app = Flask(__name__)

# ----------------------------
# Config (env vars)
# ----------------------------
# XMRig HTTP API:
# Provide a base URL here, e.g. http://xmrig:8080
XMRIG_API_URL = os.getenv("XMRIG_API_URL", "").strip()
XMRIG_API_TOKEN = os.getenv("XMRIG_API_TOKEN", "").strip() or None

# Optional: Per-worker XMRig API URL template.
# If set, worker detail pages will query the connecting miner's IP.
# Example: http://{ip}:8080
XMRIG_WORKER_API_URL_TEMPLATE = os.getenv("XMRIG_WORKER_API_URL_TEMPLATE", "http://{ip}:14141").strip()

# Optional: XMRig-Proxy API URL (for per-worker hashrates via /workers.json)
# Example: http://xmrig-proxy:8080
XMRIG_PROXY_URL = os.getenv("XMRIG_PROXY_URL", "").strip()
XMRIG_PROXY_TOKEN = os.getenv("XMRIG_PROXY_TOKEN", "").strip() or XMRIG_API_TOKEN

# Timeouts: keep these short so the UI stays snappy even if a miner is down.
try:
    XMRIG_API_TIMEOUT = float(os.getenv("XMRIG_API_TIMEOUT", "1.5"))
except Exception:
    XMRIG_API_TIMEOUT = 1.5

# P2Pool version display:
# P2Pool doesn't include its own version in the data-api JSON files.
# Set P2POOL_VERSION directly, or write a one-line version file to the shared /data volume.
P2POOL_VERSION = os.getenv("P2POOL_VERSION", "").strip()
P2POOL_VERSION_FILE = os.getenv("P2POOL_VERSION_FILE", "/data/p2pool_version").strip()

# UI version (purely cosmetic)
UI_VERSION = "v1.1.0"


# ----------------------------
# Jinja helpers
# ----------------------------

def timeago(value):
    if value is None:
        return ""
    try:
        dt = datetime.fromtimestamp(int(value)).replace(microsecond=0)
        now = datetime.now().replace(microsecond=0)
        return humanfriendly.format_timespan(now - dt)
    except Exception:
        return "unknown"


app.jinja_env.filters["timeago"] = timeago


def human_numbers(value):
    if value is None:
        return ""
    try:
        return "{:!.3h}".format(Float(value))
    except Exception:
        return str(value)


app.jinja_env.filters["humanize"] = human_numbers


def timespan(value):
    """Format a duration in seconds as a friendly timespan."""
    if value is None:
        return ""
    try:
        return humanfriendly.format_timespan(int(value))
    except Exception:
        return str(value)


app.jinja_env.filters["timespan"] = timespan


# ----------------------------
# File helpers
# ----------------------------

def load_json(path: str):
    """Load JSON from a file path.

    Uses strict=False because some producers may emit slightly non-standard JSON
    (or truncated output during startup).
    """
    with open(path, "r") as f:
        return json.loads(f.read(), strict=False)


def read_text_file(path: str, max_bytes: int = 4096) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(max_bytes).strip()
    except Exception:
        return ""


def birthdate() -> str:
    try:
        with open("/data/pool/blocks") as reader:
            blocks = json.loads(reader.read())
        return timeago(blocks[-1]["ts"])
    except Exception:
        return "unknown time"


def get_p2pool_version() -> str:
    if P2POOL_VERSION:
        return P2POOL_VERSION

    file_val = read_text_file(P2POOL_VERSION_FILE)
    if file_val:
        return file_val.splitlines()[0].strip() or "unknown"

    return "unknown"


# ----------------------------
# XMRig HTTP API helpers
# ----------------------------

def _normalize_base_url(url: str) -> str:
    return (url or "").rstrip("/")


def _http_get_json(url: str, token: Optional[str], timeout: float):
    headers = {
        "User-Agent": "salvium-p2pool-stats-ui",
        "Accept": "application/json",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"

    req = urllib.request.Request(url, headers=headers, method="GET")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read()

    text = body.decode("utf-8", errors="replace")
    return json.loads(text, strict=False)


def get_xmrig_summary(base_url: str, token: Optional[str]) -> Tuple[Optional[dict], Optional[str]]:
    """Fetch XMRig summary JSON.

    Tries /2/summary then /1/summary for compatibility.
    Returns (summary_dict, endpoint_used) or (None, None).
    """
    base_url = _normalize_base_url(base_url)
    if not base_url:
        return None, None

    endpoints = ["/2/summary", "/1/summary"]
    for ep in endpoints:
        url = base_url + ep
        try:
            data = _http_get_json(url, token=token, timeout=XMRIG_API_TIMEOUT)
            if isinstance(data, dict) and data:
                return data, ep
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                logger.warning("XMRig API auth failed for %s (%s)", url, e.code)
                return None, ep
            if e.code == 404:
                continue
            logger.info("XMRig API HTTP error for %s: %s", url, e)
        except (urllib.error.URLError, socket.timeout, json.JSONDecodeError) as e:
            logger.info("XMRig API unavailable at %s: %s", url, e)
        except Exception as e:
            logger.warning("Unexpected error fetching XMRig API %s: %s", url, e)

    return None, None


def get_xmrig_proxy_workers(base_url: str, token: Optional[str]) -> Optional[dict]:
    """Fetch XMRig-Proxy /workers.json if configured.

    Returns dict or None.
    """
    base_url = _normalize_base_url(base_url)
    if not base_url:
        return None

    url = base_url + "/workers.json"
    try:
        data = _http_get_json(url, token=token, timeout=XMRIG_API_TIMEOUT)
        if isinstance(data, dict) and "workers" in data:
            return data
    except Exception as e:
        logger.info("XMRig-Proxy API unavailable at %s: %s", url, e)
    return None


def xmrig_hashrate(summary: Optional[dict], idx: int):
    """Safely pull hashrate.total[idx] from an XMRig summary."""
    if not summary:
        return None
    try:
        total = summary.get("hashrate", {}).get("total", [])
        if idx < len(total):
            return total[idx]
    except Exception:
        return None
    return None


# ----------------------------
# P2Pool worker parsing
# ----------------------------

_RE_IPV6_BRACKET = re.compile(r"^\[(?P<ip>[^\]]+)\]:(?P<port>\d+)$")


def parse_addr_ip(addr: str) -> str:
    """Extract the IP from a p2pool addrString."""
    addr = (addr or "").strip()
    m = _RE_IPV6_BRACKET.match(addr)
    if m:
        return m.group("ip")

    if ":" in addr:
        return addr.rsplit(":", 1)[0]

    return addr


def encode_worker_id(addr: str) -> str:
    return urllib.parse.quote(addr, safe="")


def decode_worker_id(worker_id: str) -> str:
    return urllib.parse.unquote(worker_id)


def parse_p2pool_worker_line(line: str):
    """Parse a single entry from /data/local/stratum "workers" list.

    Format (from p2pool local-api):
      addrString, uptimeSeconds, difficulty, hashrateEstimate, customUser
    """
    parts = (line or "").split(",")
    if len(parts) < 4:
        raise ValueError("Unexpected worker format")

    addr = parts[0]
    uptime_seconds = int(parts[1])
    difficulty = int(parts[2])
    est_hashrate = int(parts[3])
    custom_user = parts[4] if len(parts) > 4 else ""

    name = custom_user if custom_user and custom_user != "x" else addr

    return {
        "id": encode_worker_id(addr),
        "addr": addr,
        "ip": parse_addr_ip(addr),
        "name": name,
        "uptime_seconds": uptime_seconds,
        "uptime": humanfriendly.format_timespan(uptime_seconds),
        "difficulty": difficulty,
        "difficulty_h": human_numbers(difficulty),
        "hashrate_raw": est_hashrate,
        "hashrate": human_numbers(est_hashrate) + "H/s",
    }


def build_worker_list(local_stats: dict):
    workers = []
    total_est_hashrate = 0
    for w in local_stats.get("workers", []) or []:
        try:
            parsed = parse_p2pool_worker_line(w)
            total_est_hashrate += parsed["hashrate_raw"]
            workers.append(parsed)
        except Exception as e:
            logger.error("Error parsing worker %s: %s", w, e)

    workers.sort(key=lambda x: x.get("hashrate_raw", 0), reverse=True)
    return workers, total_est_hashrate


def worker_xmrig_base_url(worker: dict) -> str:
    """Choose which base URL to use for a worker detail page."""
    if XMRIG_WORKER_API_URL_TEMPLATE:
        try:
            return XMRIG_WORKER_API_URL_TEMPLATE.format(ip=worker.get("ip", ""), addr=worker.get("addr", ""), name=worker.get("name", ""))
        except Exception:
            # If the template is malformed, fall back.
            pass

    return XMRIG_API_URL


# ----------------------------
# Routes
# ----------------------------

@app.route("/")
def render_index():
    try:
        my_bday = birthdate()
        p2pool_version = get_p2pool_version()

        stats_mod = load_json("/data/stats_mod")
        pool_stats = load_json("/data/pool/stats")
        network_stats = load_json("/data/network/stats")
        local_stats = load_json("/data/local/stratum")

        workers, total_est_hashrate = build_worker_list(local_stats)

        # XMRig summary (single miner)
        xmrig_summary, xmrig_ep = get_xmrig_summary(XMRIG_API_URL, XMRIG_API_TOKEN)
        xmrig_ok = xmrig_summary is not None

        # Optional: XMRig-proxy workers for accurate per-worker hashrates
        xmrig_proxy_workers = get_xmrig_proxy_workers(XMRIG_PROXY_URL, XMRIG_PROXY_TOKEN)

        # --- Metrics ---
        # Network hashrate (Difficulty / 120s block time)
        net_hashrate = network_stats.get("difficulty", 0) / 120 if network_stats.get("difficulty") else 0

        # Daily yield (prefer XMRig 15m if available)
        my_avg_hr = xmrig_hashrate(xmrig_summary, 2)
        if my_avg_hr is None:
            my_avg_hr = local_stats.get("hashrate_15m", 0)

        block_reward = network_stats.get("reward", 0) / 100000000  # 8 decimals
        if net_hashrate > 0:
            daily_yield = (float(my_avg_hr) / float(net_hashrate)) * 720 * float(block_reward)
        else:
            daily_yield = 0.0

        # Current hashrate to display: prefer XMRig 10s if available
        current_hashrate = xmrig_hashrate(xmrig_summary, 0)
        if current_hashrate is None:
            current_hashrate = total_est_hashrate

        return render_template(
            "index.html",
            my_bday=my_bday,
            ui_version=UI_VERSION,
            p2pool_version=p2pool_version,
            stats_mod=stats_mod,
            pool_stats=pool_stats,
            network_stats=network_stats,
            local_stats=local_stats,
            workers=workers[:30],
            # Combined metrics
            current_hashrate=current_hashrate,
            current_hashrate_source=("xmrig" if xmrig_ok and xmrig_hashrate(xmrig_summary, 0) is not None else "p2pool"),
            p2pool_est_hashrate=total_est_hashrate,
            net_hashrate=net_hashrate,
            daily_yield="{:.4f}".format(daily_yield),
            # XMRig
            xmrig_ok=xmrig_ok,
            xmrig_summary=xmrig_summary,
            xmrig_endpoint=xmrig_ep,
            xmrig_url=XMRIG_API_URL,
            xmrig_proxy_workers=xmrig_proxy_workers,
            xmrig_proxy_url=XMRIG_PROXY_URL,
        )

    except Exception as e:
        logger.error("UI Crash Details:\n%s", traceback.format_exc())
        return render_template("oops.html", error=str(e))


@app.route("/worker/<path:worker_id>")
def render_worker(worker_id: str):
    """Worker detail page.

    The worker_id is derived from the worker's addrString.
    We only allow IDs that currently appear in /data/local/stratum.
    """
    try:
        local_stats = load_json("/data/local/stratum")
        workers, _ = build_worker_list(local_stats)

        addr = decode_worker_id(worker_id)
        worker = next((w for w in workers if w.get("addr") == addr), None)
        if not worker:
            abort(404)

        base_url = worker_xmrig_base_url(worker)
        xmrig_summary, xmrig_ep = get_xmrig_summary(base_url, XMRIG_API_TOKEN)
        xmrig_ok = xmrig_summary is not None

        return render_template(
            "worker.html",
            ui_version=UI_VERSION,
            worker=worker,
            xmrig_ok=xmrig_ok,
            xmrig_summary=xmrig_summary,
            xmrig_endpoint=xmrig_ep,
            xmrig_base_url=_normalize_base_url(base_url),
        )

    except Exception as e:
        logger.error("Worker page crash:\n%s", traceback.format_exc())
        return render_template("oops.html", error=str(e))


@app.route("/xmrig")
def render_xmrig():
    """Dedicated XMRig summary page (single miner)."""
    try:
        xmrig_summary, xmrig_ep = get_xmrig_summary(XMRIG_API_URL, XMRIG_API_TOKEN)
        xmrig_ok = xmrig_summary is not None

        return render_template(
            "xmrig.html",
            ui_version=UI_VERSION,
            xmrig_ok=xmrig_ok,
            xmrig_summary=xmrig_summary,
            xmrig_endpoint=xmrig_ep,
            xmrig_base_url=_normalize_base_url(XMRIG_API_URL),
        )

    except Exception as e:
        logger.error("XMRig page crash:\n%s", traceback.format_exc())
        return render_template("oops.html", error=str(e))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
