#!/usr/bin/env python3
import sys
import time


def validate_jpeg(payload):
    if len(payload) < 4 or not payload.startswith(b"\xff\xd8") or not payload.endswith(b"\xff\xd9"):
        raise ValueError("invalid JPEG payload from KFCv2")
    return payload


def make_compressed_message(payload, stamp):
    from sensor_msgs.msg import CompressedImage

    message = CompressedImage()
    message.header.stamp = stamp
    message.format = "jpeg"
    message.data = payload
    return message


def advance_publication_deadline(deadline, now, fps):
    if fps <= 0:
        raise ValueError("fps must be positive")
    period = 1.0 / fps
    if deadline is None:
        return True, now + period
    if now < deadline:
        return False, deadline
    elapsed_periods = int((now - deadline) // period) + 1
    return True, deadline + elapsed_periods * period


def main():
    import gi

    gi.require_version("Gst", "1.0")
    from gi.repository import Gst

    import rclpy
    from rclpy.node import Node
    from rclpy.qos import qos_profile_sensor_data
    from sensor_msgs.msg import CompressedImage

    class Kfcv2UsbPublisher(Node):
        def __init__(self):
            super().__init__("kfcv2_usb_publisher")
            self.declare_parameter("device", "/dev/kfcv2-camera")
            self.declare_parameter("width", 3840)
            self.declare_parameter("height", 1080)
            self.declare_parameter("fps", 30)
            self.declare_parameter("topic", "/camera/kfc_compressed")
            self.declare_parameter("startup_timeout_sec", 8.0)
            self.declare_parameter("frame_timeout_sec", 3.0)

            self.device = self.get_parameter("device").value
            self.width = int(self.get_parameter("width").value)
            self.height = int(self.get_parameter("height").value)
            self.fps = int(self.get_parameter("fps").value)
            self.topic = self.get_parameter("topic").value
            self.startup_timeout_sec = float(self.get_parameter("startup_timeout_sec").value)
            self.frame_timeout_sec = float(self.get_parameter("frame_timeout_sec").value)
            self.publisher = self.create_publisher(
                CompressedImage, self.topic, qos_profile_sensor_data
            )
            self.pipeline = None
            self.sink = None
            self.bus = None

        def configure_pipeline(self):
            description = (
                f"v4l2src device={self.device} do-timestamp=true ! "
                f"image/jpeg,width={self.width},height={self.height},framerate={self.fps}/1 ! "
                "appsink name=sink emit-signals=false sync=false max-buffers=2 drop=true"
            )
            try:
                self.pipeline = Gst.parse_launch(description)
            except Exception as exc:
                raise RuntimeError(f"KFCv2 caps negotiation failed: {exc}") from exc
            self.sink = self.pipeline.get_by_name("sink")
            self.bus = self.pipeline.get_bus()

        def start(self):
            result = self.pipeline.set_state(Gst.State.PLAYING)
            if result == Gst.StateChangeReturn.FAILURE:
                raise RuntimeError(f"cannot open KFCv2 device: {self.device}")

        def stop(self):
            if self.pipeline is not None:
                self.pipeline.set_state(Gst.State.NULL)

        def raise_for_bus_error(self):
            message = self.bus.pop_filtered(Gst.MessageType.ERROR | Gst.MessageType.EOS)
            if message is None:
                return
            if message.type == Gst.MessageType.ERROR:
                error, debug = message.parse_error()
                detail = f"{error.message} {debug or ''}".lower()
                if "not-negotiated" in detail or "caps" in detail:
                    raise RuntimeError(f"KFCv2 caps negotiation failed: {error.message}")
                raise RuntimeError(f"cannot open KFCv2 device: {error.message}")
            raise RuntimeError("KFCv2 frame stream timed out or disconnected")

        def pull_payload(self):
            sample = self.sink.emit("try-pull-sample", 200 * Gst.MSECOND)
            if sample is None:
                self.raise_for_bus_error()
                return None
            buffer = sample.get_buffer()
            success, mapping = buffer.map(Gst.MapFlags.READ)
            if not success:
                raise RuntimeError("invalid JPEG payload from KFCv2")
            try:
                return validate_jpeg(bytes(mapping.data))
            finally:
                buffer.unmap(mapping)

        def publish_payload(self, payload):
            stamp = self.get_clock().now().to_msg()
            self.publisher.publish(make_compressed_message(payload, stamp))

    rclpy.init()
    node = None
    exit_code = 0
    try:
        node = Kfcv2UsbPublisher()
        Gst.init(None)
        node.configure_pipeline()
        node.start()
        started_at = time.monotonic()
        last_frame_at = None
        next_publish_at = None
        while rclpy.ok():
            payload = node.pull_payload()
            now = time.monotonic()
            if payload is not None:
                last_frame_at = now
                should_publish, next_publish_at = advance_publication_deadline(
                    next_publish_at, now, node.fps
                )
                if should_publish:
                    node.publish_payload(payload)
            elif last_frame_at is None and now - started_at >= node.startup_timeout_sec:
                raise RuntimeError("no KFCv2 frame before startup timeout")
            elif last_frame_at is not None and now - last_frame_at >= node.frame_timeout_sec:
                raise RuntimeError("KFCv2 frame stream timed out or disconnected")
            rclpy.spin_once(node, timeout_sec=0.0)
    except (RuntimeError, ValueError) as exc:
        if node is not None:
            node.get_logger().fatal(str(exc))
        else:
            print(str(exc), file=sys.stderr)
        exit_code = 1
    finally:
        if node is not None:
            node.stop()
            node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
