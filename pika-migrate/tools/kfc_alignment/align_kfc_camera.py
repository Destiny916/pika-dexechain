#!/usr/bin/env python3
"""Visually align a live KFCv2 camera against a reference image."""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import cv2
import numpy as np


WINDOW_NAME = "KFCv2 Camera Alignment"


def alpha_value(value: str) -> float:
    try:
        alpha = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("alpha must be a number in [0, 1]") from exc
    if not 0.0 <= alpha <= 1.0:
        raise argparse.ArgumentTypeError("alpha must be in [0, 1]")
    return alpha


def positive_float(value: str) -> float:
    try:
        number = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("value must be a positive number") from exc
    if number <= 0:
        raise argparse.ArgumentTypeError("value must be positive")
    return number


def load_image(path: Path) -> np.ndarray:
    """Read an image, including paths containing non-ASCII characters."""
    path = path.expanduser().resolve()
    if not path.is_file():
        raise FileNotFoundError(f"reference image does not exist: {path}")
    encoded = np.fromfile(path, dtype=np.uint8)
    image = cv2.imdecode(encoded, cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError(f"failed to decode reference image: {path}")
    return image


def decode_flag_for_width(target_width: int) -> tuple[int, int]:
    """Choose cheap JPEG reduced decoding when the reference is small."""
    if target_width <= 960:
        return cv2.IMREAD_REDUCED_COLOR_4, 4
    if target_width <= 1920:
        return cv2.IMREAD_REDUCED_COLOR_2, 2
    return cv2.IMREAD_COLOR, 1


def decode_and_resize(payload: bytes, target_size: tuple[int, int], decode_flag: int) -> np.ndarray:
    live = cv2.imdecode(np.frombuffer(payload, dtype=np.uint8), decode_flag)
    if live is None:
        raise ValueError("failed to decode live JPEG frame")
    target_width, target_height = target_size
    if live.shape[1] == target_width and live.shape[0] == target_height:
        return live
    shrinking = live.shape[1] > target_width or live.shape[0] > target_height
    interpolation = cv2.INTER_AREA if shrinking else cv2.INTER_LINEAR
    return cv2.resize(live, target_size, interpolation=interpolation)


def compose_view(live: np.ndarray, reference: np.ndarray, ghost_alpha: float) -> np.ndarray:
    if live.shape != reference.shape:
        raise ValueError(f"live/reference shape mismatch: {live.shape} != {reference.shape}")
    return cv2.addWeighted(live, 1.0 - ghost_alpha, reference, ghost_alpha, 0.0)


def window_is_open(name: str) -> bool:
    try:
        _x, _y, width, height = cv2.getWindowImageRect(name)
    except cv2.error:
        return False
    return width > 0 and height > 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Overlay a reference image as a ghost layer under a live KFCv2 "
            "sensor_msgs/CompressedImage topic."
        )
    )
    parser.add_argument("--topic", required=True, help="Live KFC CompressedImage topic")
    parser.add_argument("--reference", required=True, type=Path, help="Reference image path")
    parser.add_argument(
        "--alpha",
        type=alpha_value,
        default=0.5,
        help="Initial reference/ghost opacity in [0, 1] (default: 0.5)",
    )
    parser.add_argument(
        "--fps",
        type=positive_float,
        default=10.0,
        help="Maximum display refresh rate (default: 10)",
    )
    parser.add_argument(
        "--window-width",
        type=int,
        default=1600,
        help="Initial window width; 0 uses reference width (default: 1600)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.window_width < 0:
        raise SystemExit("--window-width must be non-negative")

    try:
        reference_path = args.reference.expanduser().resolve()
        reference = load_image(reference_path)
    except (FileNotFoundError, ValueError) as exc:
        raise SystemExit(str(exc)) from exc

    try:
        import rclpy
        from rclpy.node import Node
        from rclpy.qos import DurabilityPolicy, HistoryPolicy, QoSProfile, ReliabilityPolicy
        from sensor_msgs.msg import CompressedImage
    except ImportError as exc:
        raise SystemExit(
            "ROS 2 Python dependencies are unavailable. Run after sourcing "
            "/opt/ros/humble/setup.bash and use /usr/bin/python3 (not Conda Python)."
        ) from exc

    target_height, target_width = reference.shape[:2]
    target_size = (target_width, target_height)
    decode_flag, decode_reduction = decode_flag_for_width(target_width)

    latest_payload: bytes | None = None
    received = 0
    decode_errors = 0

    rclpy.init(args=[])
    node = Node("kfc_camera_alignment_viewer")
    qos = QoSProfile(
        history=HistoryPolicy.KEEP_LAST,
        depth=1,
        reliability=ReliabilityPolicy.BEST_EFFORT,
        durability=DurabilityPolicy.VOLATILE,
    )

    def receive(message: CompressedImage) -> None:
        nonlocal latest_payload, received
        latest_payload = bytes(message.data)
        received += 1

    node.create_subscription(CompressedImage, args.topic, receive, qos)

    cv2.namedWindow(WINDOW_NAME, cv2.WINDOW_NORMAL)
    initial_width = target_width if args.window_width == 0 else min(args.window_width, target_width)
    initial_height = max(1, round(target_height * initial_width / target_width))
    cv2.resizeWindow(WINDOW_NAME, initial_width, initial_height)
    cv2.createTrackbar("Ghost %", WINDOW_NAME, round(args.alpha * 100), 100, lambda _value: None)

    last_display = 0.0
    last_live: np.ndarray | None = None
    last_wait_notice = 0.0
    last_rendered_alpha = -1.0
    needs_render = False
    interrupted = False
    period = 1.0 / args.fps

    print(f"topic:      {args.topic}")
    print(f"reference:  {reference_path}")
    print(f"target:     {target_width}x{target_height}")
    print(f"JPEG decode reduction: 1/{decode_reduction}")
    print("close the window to quit (Ctrl+C in the terminal is also supported)")

    waiting = reference.copy()
    cv2.putText(
        waiting,
        f"Waiting for {args.topic}",
        (24, 48),
        cv2.FONT_HERSHEY_SIMPLEX,
        1.0,
        (0, 255, 255),
        2,
        cv2.LINE_AA,
    )
    cv2.imshow(WINDOW_NAME, waiting)

    try:
        while rclpy.ok():
            rclpy.spin_once(node, timeout_sec=0.01)
            now = time.monotonic()

            if latest_payload is not None and now - last_display >= period:
                payload = latest_payload
                latest_payload = None
                try:
                    last_live = decode_and_resize(payload, target_size, decode_flag)
                    needs_render = True
                except ValueError as exc:
                    decode_errors += 1
                    if decode_errors <= 3 or decode_errors % 100 == 0:
                        node.get_logger().warning(str(exc))
                last_display = now

            if last_live is not None:
                ghost_alpha = cv2.getTrackbarPos("Ghost %", WINDOW_NAME) / 100.0
                if ghost_alpha != last_rendered_alpha:
                    needs_render = True
                if needs_render:
                    view = compose_view(last_live, reference, ghost_alpha)
                    cv2.imshow(WINDOW_NAME, view)
                    title = (
                        f"{WINDOW_NAME} | ghost={ghost_alpha:.0%} | "
                        f"{target_width}x{target_height} | received={received}"
                    )
                    if hasattr(cv2, "setWindowTitle"):
                        cv2.setWindowTitle(WINDOW_NAME, title)
                    last_rendered_alpha = ghost_alpha
                    needs_render = False
            elif now - last_wait_notice >= 5.0:
                print(f"waiting for frames on {args.topic} ...", file=sys.stderr)
                last_wait_notice = now

            cv2.waitKey(1)
            if not window_is_open(WINDOW_NAME):
                break
    except KeyboardInterrupt:
        interrupted = True
    finally:
        cv2.destroyAllWindows()
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()

    if interrupted:
        print("alignment cancelled by Ctrl+C", file=sys.stderr)
        return 130
    if received == 0:
        print(f"no live frames were received on {args.topic}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
