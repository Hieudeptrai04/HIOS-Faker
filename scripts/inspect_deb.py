#!/usr/bin/env python3
"""Inspect .deb file and verify it contains compiled dylib."""
import sys
import zlib
import tarfile
import io

def inspect_deb(deb_path):
    with open(deb_path, 'rb') as f:
        data = f.read()

    print(f"Total .deb size: {len(data)} bytes")

    pos = 8
    while pos < len(data):
        h = data[pos:pos+60]
        name = h[:16].decode('ascii', 'replace').strip('/')
        fsize = int(h[48:58].decode('ascii', 'replace').strip())
        pos += 60
        fdata = data[pos:pos+fsize]
        pos += fsize
        if fsize % 2:
            pos += 1

        if 'data.tar' in name:
            tf = tarfile.open(fileobj=io.BytesIO(zlib.decompress(fdata, 16 + zlib.MAX_WBITS)))
            print(f"data.tar.gz size: {fsize} bytes, {len(tf.getmembers())} files")
            has_dylib = False
            for m in tf.getmembers():
                if '.dylib' in m.name:
                    has_dylib = True
                    print(f"  {m.name} ({m.size}b)  <-- DYLIB")
                elif '.plist' in m.name:
                    print(f"  {m.name} ({m.size}b)")
                elif m.isfile():
                    print(f"  {m.name} ({m.size}b)")
            return has_dylib
    return False

if __name__ == '__main__':
    deb_path = sys.argv[1] if len(sys.argv) > 1 else 'package.deb'
    try:
        has_dylib = inspect_deb(deb_path)
        if has_dylib:
            print("\nOK: .deb contains compiled dylib")
            sys.exit(0)
        else:
            print("\nERROR: No dylib found in .deb!")
            sys.exit(1)
    except Exception as e:
        print(f"ERROR: {e}")
        sys.exit(1)
