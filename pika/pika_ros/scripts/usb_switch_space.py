#!/usr/bin/env python3
"""Convert one USB switch press into one space key event."""

import os
import subprocess
import sys
import time

from evdev import InputDevice, ecodes, list_devices

TARGET = "/dev/input/by-id/usb-2704_2018-event-kbd"


def find_device():
    try:
        return InputDevice(TARGET)
    except FileNotFoundError:
        pass

    for path in list_devices():
        device = InputDevice(path)
        if "2704" in device.info and "2018" in device.info:
            return device
    return None


def main():
    device = find_device()
    if device is None:
        print("ERROR: USB switch 2704:2018 was not found", file=sys.stderr)
        return 1
    print(f"Listening: {device.path} ({device.name})", flush=True)
    print("One press -> one space; Ctrl-C exits", flush=True)
    display = os.environ.get("DISPLAY", ":0")
    xauthority = os.environ.get("XAUTHORITY", os.path.expanduser("~/.Xauthority"))
    try:
        for event in device.read_loop():
            if event.type != ecodes.EV_KEY or event.value != 1:
                continue
            print(f"key press: code={event.code}", flush=True)
            env = os.environ.copy()
            env["DISPLAY"] = display
            env["XAUTHORITY"] = xauthority
            subprocess.run(["xdotool", "key", "--clearmodifiers", "space"], env=env, check=False)
            time.sleep(0.05)
    except KeyboardInterrupt:
        print("\nStopped.", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
