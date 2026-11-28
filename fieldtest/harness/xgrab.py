"""Grabs a region of an X display to a PNG in a few milliseconds.

ffmpeg needs 50-150 ms to start a one-frame grab, long enough for a ticking
chart to change; XGetImage on an open connection does not. Pure standard
library: ctypes on libX11, zlib for the PNG.
"""
import ctypes
import ctypes.util
import struct
import time
import zlib


class _XImage(ctypes.Structure):
    _fields_ = [
        ('width', ctypes.c_int), ('height', ctypes.c_int), ('xoffset', ctypes.c_int),
        ('format', ctypes.c_int), ('data', ctypes.c_void_p), ('byte_order', ctypes.c_int),
        ('bitmap_unit', ctypes.c_int), ('bitmap_bit_order', ctypes.c_int), ('bitmap_pad', ctypes.c_int),
        ('depth', ctypes.c_int), ('bytes_per_line', ctypes.c_int), ('bits_per_pixel', ctypes.c_int),
        ('red_mask', ctypes.c_ulong), ('green_mask', ctypes.c_ulong), ('blue_mask', ctypes.c_ulong),
    ]


_ALL_PLANES = 0xFFFFFFFFFFFFFFFF
_Z_PIXMAP = 2


class Grabber:
    def __init__(self, display):
        name = ctypes.util.find_library('X11')
        if not name:
            raise RuntimeError('libX11 not found')
        x = ctypes.cdll.LoadLibrary(name)
        x.XOpenDisplay.restype = ctypes.c_void_p
        x.XOpenDisplay.argtypes = [ctypes.c_char_p]
        x.XDefaultRootWindow.restype = ctypes.c_ulong
        x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        x.XGetImage.restype = ctypes.POINTER(_XImage)
        x.XGetImage.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
                                ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_int]
        x.XFree.argtypes = [ctypes.c_void_p]
        x.XCloseDisplay.argtypes = [ctypes.c_void_p]
        x.XCreateSimpleWindow.restype = ctypes.c_ulong
        x.XCreateSimpleWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_uint,
                                          ctypes.c_uint, ctypes.c_uint, ctypes.c_ulong, ctypes.c_ulong]
        for name in ('XMapRaised', 'XClearWindow', 'XDestroyWindow'):
            getattr(x, name).argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        x.XSetWindowBackground.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong]
        x.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self._x = x
        self._d = x.XOpenDisplay(display.encode())
        if not self._d:
            raise RuntimeError(f'cannot open display {display}')
        self._root = x.XDefaultRootWindow(self._d)

    def grab(self, x, y, w, h):
        """Returns (epoch ms at the grab, RGB bytes)."""
        at = time.time() * 1000
        img = self._x.XGetImage(self._d, self._root, x, y, w, h, _ALL_PLANES, _Z_PIXMAP)
        if not img:
            raise RuntimeError('XGetImage failed')
        try:
            im = img.contents
            if im.bits_per_pixel != 32:
                raise RuntimeError(f'{im.bits_per_pixel} bits per pixel')
            stride = im.bytes_per_line
            raw = ctypes.string_at(im.data, stride * h)
        finally:
            self._x.XFree(img.contents.data)
            self._x.XFree(img)
        # BGRX rows (little endian, 24-bit depth) to RGB.
        rgb = bytearray(w * h * 3)
        for row in range(h):
            line = raw[row * stride: row * stride + w * 4]
            o = row * w * 3
            rgb[o:o + w * 3:3] = line[2::4]
            rgb[o + 1:o + w * 3:3] = line[1::4]
            rgb[o + 2:o + w * 3:3] = line[0::4]
        return at, bytes(rgb)

    def png(self, path, x, y, w, h):
        """Writes a PNG; returns the epoch ms of the grab."""
        at, rgb = self.grab(x, y, w, h)
        write_png(path, w, h, rgb)
        return at

    def flash(self, x, y, w, h, hold_s=0.8):
        """The sync flash of tools/replay-render/sync.mjs, drawn on the X display: a
        magenta window for [hold_s], then green in one step. Returns the epoch ms of
        the switch (syncEpochMs), taken once the server has drawn the green."""
        win = self._x.XCreateSimpleWindow(self._d, self._root, x, y, w, h, 0, 0, 0xFF00FF)
        self._x.XMapRaised(self._d, win)
        self._x.XSync(self._d, 0)
        time.sleep(hold_s)
        self._x.XSetWindowBackground(self._d, win, 0x00FF00)
        self._x.XClearWindow(self._d, win)
        self._x.XSync(self._d, 0)
        at = time.time() * 1000
        time.sleep(0.3)
        self._x.XDestroyWindow(self._d, win)
        self._x.XSync(self._d, 0)
        return at

    def close(self):
        if self._d:
            self._x.XCloseDisplay(self._d)
            self._d = None


def write_png(path, w, h, rgb):
    def chunk(kind, data):
        c = kind + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)

    stride = w * 3
    raw = b''.join(b'\x00' + rgb[r * stride:(r + 1) * stride] for r in range(h))
    data = (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(raw, 6))
            + chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(data)


if __name__ == '__main__':
    import sys
    g = Grabber(sys.argv[1])
    t0 = time.time()
    at = g.png(sys.argv[2], *[int(v) for v in sys.argv[3:7]])
    print(f'grabbed at {at:.0f}, {1000 * (time.time() - t0):.1f} ms')
