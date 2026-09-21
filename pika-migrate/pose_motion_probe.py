#!/usr/bin/env python3
"""Measure simultaneous motion on the two Pika PoseStamped topics."""

from __future__ import annotations

import argparse
import math
import os
import time

import rclpy
from geometry_msgs.msg import PoseStamped
from rclpy.qos import DurabilityPolicy, HistoryPolicy, QoSProfile, ReliabilityPolicy


def quaternion_angle(a: tuple[float, ...], b: tuple[float, ...]) -> float:
    dot = abs(sum(x * y for x, y in zip(a, b)))
    dot = min(1.0, max(-1.0, dot))
    return 2.0 * math.acos(dot)


def summarize(samples: list[tuple[tuple[float, ...], tuple[float, ...]]]) -> tuple[float, float, float]:
    if len(samples) < 2:
        return 0.0, 0.0, 0.0

    positions = [sample[0] for sample in samples]
    translations = [
        max(position[axis] for position in positions)
        - min(position[axis] for position in positions)
        for axis in range(3)
    ]
    translation_span = math.sqrt(sum(value * value for value in translations))

    reference = samples[0][1]
    rotation_span = max(quaternion_angle(reference, sample[1]) for sample in samples)

    # 1 rad of rotation counts like 15 cm of translation. This keeps pure wrist
    # rotation detectable without letting normal orientation noise dominate.
    score = translation_span + 0.15 * rotation_span
    return translation_span, rotation_span, score


def pose_tuple(message: PoseStamped) -> tuple[tuple[float, ...], tuple[float, ...]]:
    position = message.pose.position
    orientation = message.pose.orientation
    return (
        (position.x, position.y, position.z),
        (orientation.x, orientation.y, orientation.z, orientation.w),
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration", type=float, default=4.0)
    parser.add_argument("--left-topic", default="/pika_pose_l")
    parser.add_argument("--right-topic", default="/pika_pose_r")
    args = parser.parse_args()

    rclpy.init()
    node = rclpy.create_node(f"pika_pose_motion_probe_{os.getpid()}")
    qos = QoSProfile(
        history=HistoryPolicy.KEEP_LAST,
        depth=100,
        reliability=ReliabilityPolicy.BEST_EFFORT,
        durability=DurabilityPolicy.VOLATILE,
    )
    left_samples: list[tuple[tuple[float, ...], tuple[float, ...]]] = []
    right_samples: list[tuple[tuple[float, ...], tuple[float, ...]]] = []
    node.create_subscription(
        PoseStamped,
        args.left_topic,
        lambda message: left_samples.append(pose_tuple(message)),
        qos,
    )
    node.create_subscription(
        PoseStamped,
        args.right_topic,
        lambda message: right_samples.append(pose_tuple(message)),
        qos,
    )

    deadline = time.monotonic() + args.duration
    try:
        while time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.1)
    except KeyboardInterrupt:
        return 130
    finally:
        node.destroy_node()
        rclpy.shutdown()

    left_translation, left_rotation, left_score = summarize(left_samples)
    right_translation, right_rotation, right_score = summarize(right_samples)
    print(
        "left:"
        f" samples={len(left_samples)}"
        f" translation_span={left_translation:.4f}m"
        f" rotation_span={left_rotation:.4f}rad"
        f" score={left_score:.4f}"
    )
    print(
        "right:"
        f" samples={len(right_samples)}"
        f" translation_span={right_translation:.4f}m"
        f" rotation_span={right_rotation:.4f}rad"
        f" score={right_score:.4f}"
    )
    print(
        f"RESULT {left_score:.9f} {right_score:.9f}"
        f" {len(left_samples)} {len(right_samples)}"
    )
    if len(left_samples) < 3 or len(right_samples) < 3:
        print("ERROR: one or both pose topics produced fewer than 3 samples")
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
