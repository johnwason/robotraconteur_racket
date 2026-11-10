"""Loopback camera for testing the camera examples without a device.

Serves com.robotraconteur.imaging.Camera with synthetic frames:

  - a 96x48 rgb888 image whose left third is red, middle third green and
    right third blue, so a test can tell whether colour channels were swapped;
  - capture_frame_compressed and the frame_stream_compressed and
    preview_stream pipes carry the same image as PNG (pure Python, no imaging
    libraries needed);
  - start_streaming sends frames on all three pipes about 20 times a second
    until stop_streaming.

    python3 test/loopback_camera.py [port]

Serves rr+tcp://localhost:<port>/?service=camera (default port 59830).
"""

import struct
import sys
import threading
import time
import zlib

import numpy as np
import RobotRaconteur as RR
import RobotRaconteurCompanion as RRC

RRN = RR.RobotRaconteurNode.s

WIDTH, HEIGHT = 96, 48


def make_pixels():
    """rgb888 pixel data, rows top to bottom"""
    row = bytearray()
    for x in range(WIDTH):
        third = 3 * x // WIDTH
        row += bytes([255, 0, 0]) if third == 0 else bytes([0, 255, 0]) if third == 1 else bytes([0, 0, 255])
    return bytes(row) * HEIGHT


def png_encode(pixels, width, height):
    """Encode rgb888 pixels as a PNG file"""
    def chunk(kind, data):
        c = struct.pack(">I", len(data)) + kind + data
        return c + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + pixels[y * width * 3:(y + 1) * width * 3] for y in range(height))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


class LoopbackCamera:
    def __init__(self):
        self._image_type = RRN.GetStructureType("com.robotraconteur.image.Image")
        self._compressed_type = RRN.GetStructureType("com.robotraconteur.image.CompressedImage")
        self._info_type = RRN.GetStructureType("com.robotraconteur.image.ImageInfo")
        enc = RRN.GetConstants("com.robotraconteur.image")["ImageEncoding"]
        self._rgb888 = enc["rgb888"]
        self._compressed = enc["compressed"]
        self._pixels = make_pixels()
        self._png = png_encode(self._pixels, WIDTH, HEIGHT)
        self._streaming = False
        self._lock = threading.Lock()
        self._frame_b = None
        self._frame_compressed_b = None
        self._preview_b = None

    def _info(self, encoding, step):
        info = self._info_type()
        info.width = WIDTH
        info.height = HEIGHT
        info.step = step
        info.encoding = encoding
        return info

    def capture_frame(self):
        img = self._image_type()
        img.image_info = self._info(self._rgb888, WIDTH * 3)
        img.data = np.frombuffer(self._pixels, dtype=np.uint8)
        return img

    def capture_frame_compressed(self):
        img = self._compressed_type()
        img.image_info = self._info(self._compressed, 0)
        img.data = np.frombuffer(self._png, dtype=np.uint8)
        return img

    def start_streaming(self):
        with self._lock:
            if self._streaming:
                raise RR.InvalidOperationException("Already streaming")
            self._streaming = True
        threading.Thread(target=self._stream, daemon=True).start()

    def stop_streaming(self):
        with self._lock:
            if not self._streaming:
                raise RR.InvalidOperationException("Not streaming")
            self._streaming = False

    def _stream(self):
        while True:
            with self._lock:
                if not self._streaming:
                    return
            self._frame_b.AsyncSendPacket(self.capture_frame(), lambda: None)
            compressed = self.capture_frame_compressed()
            self._frame_compressed_b.AsyncSendPacket(compressed, lambda: None)
            self._preview_b.AsyncSendPacket(compressed, lambda: None)
            time.sleep(0.05)

    # Pipes are assigned by Robot Raconteur when the service is registered
    @property
    def frame_stream(self):
        return self._frame_b.Pipe

    @frame_stream.setter
    def frame_stream(self, value):
        self._frame_b = RR.PipeBroadcaster(value)

    @property
    def frame_stream_compressed(self):
        return self._frame_compressed_b.Pipe

    @frame_stream_compressed.setter
    def frame_stream_compressed(self, value):
        self._frame_compressed_b = RR.PipeBroadcaster(value)

    @property
    def preview_stream(self):
        return self._preview_b.Pipe

    @preview_stream.setter
    def preview_stream(self, value):
        self._preview_b = RR.PipeBroadcaster(value)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 59830
    RRC.RegisterStdRobDefServiceTypes(RRN)
    with RR.ServerNodeSetup("experimental.loopback_camera", port):
        RRN.RegisterService("camera", "com.robotraconteur.imaging.Camera", LoopbackCamera())
        print("READY", flush=True)
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
