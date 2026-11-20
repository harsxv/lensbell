#!/usr/bin/env python3
"""Lensbell watcher.

Polls the EZVIZ cloud (through the pyezvizapi CLI) for new alarm events.
When a camera reports a new alarm, it downloads (and decrypts) the capture
and shows a native macOS notification with the image attached.
"""
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

BASE = Path(__file__).resolve().parent
CAPTURES = BASE / "captures"
STATE_FILE = BASE / "state.json"
TOKEN_FILE = BASE / "ezviz_token.json"
CLI = str(BASE / ".venv" / "bin" / "pyezvizapi")
NOTIFIER = Path(os.environ.get(
    "LENSBELL_NOTIFIER",
    Path.home() / "Applications" / "Lensbell.app" / "Contents" / "MacOS" / "Lensbell"))
POPUP = BASE / "popup"

POLL_SECONDS = int(os.environ.get("LENSBELL_POLL_SECONDS", "10"))
REGION = os.environ.get("LENSBELL_REGION", "")  # e.g. apiisgp.ezvizlife.com
KEEP_DAYS = int(os.environ.get("LENSBELL_KEEP_DAYS", "14"))
# notification = native macOS notification (kept in Notification Center)
# popup        = large floating capture window
# both         = show both
STYLE = os.environ.get("LENSBELL_STYLE", "notification")
POPUP_SECONDS = os.environ.get("LENSBELL_POPUP_SECONDS", "12")

_popup_proc = None


def log(msg):
    print(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}", flush=True)


# --- EZVIZ cloud --------------------------------------------------------------

def cli(*args, timeout=60):
    cmd = [CLI, "--token-file", str(TOKEN_FILE)]
    if REGION:
        cmd += ["-r", REGION]
    cmd += ["--json", *args]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout).strip()[-500:])
    return r.stdout


def parse_json(text):
    text = text.strip()
    starts = [i for i in (text.find("{"), text.find("[")) if i >= 0]
    if not starts:
        raise ValueError("no JSON in CLI output")
    return json.loads(text[min(starts):])


def find_cameras(data):
    """Return {serial: {name, alarm_time, alarm_pic, alarm_type}} from any JSON shape."""
    cams = {}

    def walk(node, key_hint=None):
        if isinstance(node, dict):
            if "last_alarm_time" in node or "last_alarm_pic" in node:
                serial = (node.get("serial") or node.get("deviceSerial")
                          or key_hint or "unknown")
                cams[str(serial)] = {
                    "name": node.get("name") or node.get("deviceName") or str(serial),
                    "alarm_time": str(node.get("last_alarm_time") or ""),
                    "alarm_pic": node.get("last_alarm_pic") or "",
                    "alarm_type": node.get("last_alarm_type_name") or "",
                }
            for k, v in node.items():
                walk(v, k)
        elif isinstance(node, list):
            for item in node:
                walk(item, key_hint)

    walk(data)
    return cams


def download_capture(serial, url):
    CAPTURES.mkdir(exist_ok=True)
    out = CAPTURES / f"{serial}_{datetime.now():%Y%m%d_%H%M%S}.jpg"
    cli("save", "image", "--serial", serial, "--image-url", url,
        "--output", str(out), timeout=90)
    return out if out.exists() and out.stat().st_size > 0 else None


# --- Display ------------------------------------------------------------------

def system_notification(title, message, image):
    if not (NOTIFIER.exists() and image):
        return False
    try:
        r = subprocess.run([str(NOTIFIER), "notify", str(image), title, message],
                           capture_output=True, text=True, timeout=20)
        if r.returncode != 0:
            log(f"Notification failed ({r.returncode}): {r.stderr.strip()[-300:]}")
            return False
        return True
    except subprocess.TimeoutExpired:
        log("Notification timed out (permission not granted yet?)")
        return False


def show_popup(title, message, image):
    global _popup_proc
    if not (POPUP.exists() and image):
        return False
    if _popup_proc and _popup_proc.poll() is None:
        _popup_proc.terminate()  # replace an older popup still on screen
    try:
        _popup_proc = subprocess.Popen(
            [str(POPUP), str(image), title, message, POPUP_SECONDS],
            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        time.sleep(0.5)
        if _popup_proc.poll() not in (None, 0):
            log(f"Popup failed: {_popup_proc.stderr.read().decode()[-300:]}")
            return False
        return True
    except Exception as e:
        log(f"Popup failed: {e}")
        return False


def text_notification(title, message):
    script = (f"display notification {json.dumps(message)} "
              f"with title {json.dumps(title)} sound name \"default\"")
    subprocess.run(["osascript", "-e", script], capture_output=True)


def notify(title, message, image=None):
    shown = False
    if STYLE in ("notification", "both"):
        shown = system_notification(title, message, image)
    if STYLE in ("popup", "both") or not shown:
        shown = show_popup(title, message, image) or shown
    if not shown:
        text_notification(title, message)


# --- Main loop ----------------------------------------------------------------

def load_state():
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return {}


def save_state(state):
    STATE_FILE.write_text(json.dumps(state, indent=2))


def cleanup_old():
    if not CAPTURES.exists():
        return
    cutoff = time.time() - KEEP_DAYS * 86400
    for f in CAPTURES.glob("*.jpg"):
        if f.stat().st_mtime < cutoff:
            f.unlink(missing_ok=True)


def main():
    if not TOKEN_FILE.exists():
        sys.exit("No token found. Run ./setup.sh first to log in.")
    state = load_state()
    first_run = not state
    seen_once = False
    errors = 0
    log(f"Watcher started, polling every {POLL_SECONDS}s (style: {STYLE}).")
    while True:
        try:
            cams = find_cameras(parse_json(cli("devices", "status")))
            if not cams:
                log("Warning: no camera with a last_alarm_time field in the output.")
            if not seen_once:
                for cam in cams.values():
                    log(f"Camera: {cam['name']} | last alarm: {cam['alarm_time'] or '-'}")
                seen_once = True
            for serial, cam in cams.items():
                prev = state.get(serial)
                if cam["alarm_time"] and prev != cam["alarm_time"]:
                    state[serial] = cam["alarm_time"]
                    if first_run or prev is None:
                        continue  # don't fire for old events on first start
                    log(f"New alarm: {cam['name']} @ {cam['alarm_time']}")
                    img = None
                    if cam["alarm_pic"]:
                        try:
                            img = download_capture(serial, cam["alarm_pic"])
                        except Exception as e:
                            log(f"Image download failed: {e}")
                    label = cam["alarm_type"] or "Motion detected"
                    notify(cam["name"], f"{label} • {cam['alarm_time']}", img)
            save_state(state)
            first_run = False
            errors = 0
            cleanup_old()
        except Exception as e:
            errors += 1
            log(f"Error: {e}")
            if errors == 5:
                text_notification("Lensbell", "Can't reach EZVIZ. Check watcher.log.")
        time.sleep(POLL_SECONDS if errors == 0 else min(300, POLL_SECONDS * errors))


if __name__ == "__main__":
    main()
