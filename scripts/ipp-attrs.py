#!/usr/bin/env python3
"""Read-only IPP Get-Printer-Attributes client (Python standard library only).

    ipp-attrs.py http://localhost:8631/ipp/print/NAME [attribute ...]
    ipp-attrs.py --decode FILE            # decode a saved IPP response (used by the tests)

Prints one "name=value" line per value of each attribute. Used by scripts/discover.sh and
setup.sh to read facts back from the running server (the printer's own IPP URIs, media-ready,
state) instead of assuming them. It only ever sends Get-Printer-Attributes.
"""
import struct
import sys
import urllib.request

OPERATION_GET_PRINTER_ATTRIBUTES = 0x000B
TAG_OPERATION = 0x01
TAG_END = 0x03
TAG_CHARSET = 0x47
TAG_LANGUAGE = 0x48
TAG_URI = 0x45
TAG_KEYWORD = 0x44

# value tags of the types we render as text
TAG_INTEGER = 0x21
TAG_BOOLEAN = 0x22
TAG_ENUM = 0x23
TAG_RANGE = 0x33
TAG_RESOLUTION = 0x32
TAG_BEGIN_COLLECTION = 0x34
TAG_END_COLLECTION = 0x37
TAG_MEMBER_NAME = 0x4A


def _attr(tag, name, value):
    n = name.encode()
    v = value.encode()
    return struct.pack(">BH", tag, len(n)) + n + struct.pack(">H", len(v)) + v


def build_request(uri, wanted):
    body = struct.pack(">BBHI", 1, 1, OPERATION_GET_PRINTER_ATTRIBUTES, 1)
    body += bytes([TAG_OPERATION])
    body += _attr(TAG_CHARSET, "attributes-charset", "utf-8")
    body += _attr(TAG_LANGUAGE, "attributes-natural-language", "en")
    body += _attr(TAG_URI, "printer-uri", uri)
    for i, name in enumerate(wanted):
        body += _attr(TAG_KEYWORD, "requested-attributes" if i == 0 else "", name)
    return body + bytes([TAG_END])


def _text(tag, raw):
    if tag in (TAG_INTEGER, TAG_ENUM):
        return str(struct.unpack(">i", raw)[0])
    if tag == TAG_BOOLEAN:
        return "true" if raw[0] else "false"
    if tag == TAG_RANGE:
        lo, hi = struct.unpack(">ii", raw)
        return "%d-%d" % (lo, hi)
    if tag == TAG_RESOLUTION:
        x, y, unit = struct.unpack(">iib", raw)
        return "%dx%d%s" % (x, y, "dpi" if unit == 3 else "dpcm")
    if tag >= 0x40:
        return raw.decode("utf-8", "replace")
    return raw.hex()


def decode_response(data):
    """Return (status_code, [(name, value), ...]) for the printer attributes group.

    Collections are flattened into "member=value" text on a single line.
    """
    if len(data) < 8:
        raise ValueError("IPP response too short (%d bytes)" % len(data))
    _major, _minor, status, _request_id = struct.unpack(">BBHI", data[:8])
    pos = 8
    out = []
    current = None
    depth = 0
    collection_parts = []
    while pos < len(data):
        tag = data[pos]
        pos += 1
        if tag == TAG_END:
            break
        if tag <= 0x0F:  # delimiter tag: start of an attribute group
            continue
        (nlen,) = struct.unpack(">H", data[pos : pos + 2])
        pos += 2
        name = data[pos : pos + nlen].decode()
        pos += nlen
        (vlen,) = struct.unpack(">H", data[pos : pos + 2])
        pos += 2
        raw = data[pos : pos + vlen]
        pos += vlen
        if tag == TAG_BEGIN_COLLECTION:
            if depth == 0:
                if name:
                    current = name
                collection_parts = []   # also for the unnamed 2nd and later values of a multi-valued attribute
            depth += 1
            continue
        if tag == TAG_END_COLLECTION:
            depth -= 1
            if depth == 0:
                out.append((current, "{" + ",".join(collection_parts) + "}"))
            continue
        if depth > 0:
            if tag == TAG_MEMBER_NAME:
                collection_parts.append(raw.decode("utf-8", "replace") + "=")
            elif collection_parts:
                collection_parts[-1] += _text(tag, raw)
            continue
        if name:
            current = name
        out.append((current, _text(tag, raw)))
    return status, out


def fetch(uri, wanted):
    http = uri.replace("ipp://", "http://", 1).replace("ipps://", "https://", 1)
    req = urllib.request.Request(
        http,
        data=build_request(uri, wanted),
        headers={"Content-Type": "application/ipp"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.read()


def main(argv):
    if len(argv) >= 3 and argv[1] == "--decode":
        with open(argv[2], "rb") as fh:
            data = fh.read()
    elif len(argv) >= 2:
        uri = argv[1]
        if not uri.startswith(("http://", "https://", "ipp://", "ipps://")):
            print("ipp-attrs.py: not an http/ipp URI: %s" % uri, file=sys.stderr)
            return 2
        ipp_uri = uri.replace("http://", "ipp://", 1).replace("https://", "ipps://", 1)
        try:
            data = fetch(ipp_uri, argv[2:])
        except Exception as exc:  # network and HTTP errors: report, do not trace back
            print("ipp-attrs.py: request to %s failed: %s" % (uri, exc), file=sys.stderr)
            return 1
    else:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        status, attrs = decode_response(data)
    except (ValueError, struct.error, UnicodeDecodeError, IndexError) as exc:
        print("ipp-attrs.py: not a valid IPP response (%s)" % exc, file=sys.stderr)
        return 1
    if status >= 0x0100:
        print("ipp-attrs.py: server returned IPP status 0x%04x" % status, file=sys.stderr)
        return 1
    for name, value in attrs:
        print("%s=%s" % (name, value))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
