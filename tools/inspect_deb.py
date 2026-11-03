#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""解包 .deb 做产物体检（Windows / macOS / Linux 都能跑，无需 dpkg）。

用法： python3 tools/inspect_deb.py packages/com.cz.dockscroller_0.1.0_iphoneos-arm64e.deb
"""

import gzip
import io
import lzma
import os
import re
import struct
import sys
import tarfile


def read_ar(path):
    """返回 [(name, body_bytes), ...]"""
    with open(path, 'rb') as f:
        raw = f.read()
    if not raw.startswith(b'!<arch>\n'):
        raise SystemExit('不是 ar 归档：%s' % path)
    off = 8
    members = []
    while off + 60 <= len(raw):
        header = raw[off:off + 60]
        name = header[0:16].decode('utf-8', 'replace').strip()
        try:
            size = int(header[48:58].decode('utf-8', 'replace').strip())
        except ValueError:
            break
        off += 60
        body = raw[off:off + size]
        off += size + (size % 2)
        if name:
            members.append((name, body))
    return members


def load_tar(body):
    for opener, label in ((gzip.GzipFile, 'gz'), (lzma.LZMAFile, 'xz'),
                          (lambda f: lzma.LZMAFile(f, format=lzma.FORMAT_ALONE), 'lzma')):
        try:
            if label == 'lzma':
                return tarfile.open(fileobj=opener(io.BytesIO(body)))
            return tarfile.open(fileobj=opener(fileobj=io.BytesIO(body)))
        except Exception:
            continue
    raise SystemExit('无法解压 data 载荷（既不是 gz/xz 也不是 lzma）')


def macho_slices(blob):
    out = []
    if len(blob) < 8:
        return out
    magic = blob[:4]
    if magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        n = struct.unpack('>I', blob[4:8])[0]
        off = 8
        for _ in range(n):
            cputype, cpusub, _off, size, _align = struct.unpack('>IIIII', blob[off:off + 20])
            off += 20
            out.append((cputype, cpusub, size))
    elif magic == b'\xcf\xfa\xed\xfe':
        cputype, cpusub = struct.unpack('<ii', blob[4:12])
        out.append((cputype & 0xffffffff, cpusub & 0xffffffff, len(blob)))
    return out


def slice_name(cputype, cpusub):
    if cputype in (0x0100000D, 0x0000000D):
        return 'arm64e'
    if cputype in (0x0100000C, 0x0000000C):
        sub = cpusub & 0x00FFFFFF
        return {0: 'arm64', 1: 'arm64', 2: 'arm64e'}.get(sub, 'arm64(sub=%d)' % sub)
    return hex(cputype)


def has(blob, text):
    return (text.encode('utf-8') in blob) or (text.encode('utf-16-le') in blob)


def main():
    if len(sys.argv) < 2:
        raise SystemExit('用法：inspect_deb.py <deb> [关键字...]')
    path = sys.argv[1]
    keywords = sys.argv[2:] or ['DockScroller', 'Dock 轮播']

    members = read_ar(path)
    control = ''
    data = None
    for name, body in members:
        if name.startswith('control.tar'):
            try:
                with load_tar(body) as tf:
                    for m in tf.getmembers():
                        if os.path.basename(m.name) == 'control':
                            control = tf.extractfile(m).read().decode('utf-8', 'replace')
            except SystemExit:
                pass
        if name.startswith('data.tar'):
            data = body

    print('=== 包：%s (%.1f KB) ===' % (os.path.basename(path), os.path.getsize(path) / 1024.0))
    print(control.strip())

    arch = re.search(r'^Architecture:\s*(\S+)', control, re.M)
    if not arch or arch.group(1) != 'iphoneos-arm64e':
        print('  !! Architecture 不是 iphoneos-arm64e（roothide 的 Sileo 会拒装）')
    else:
        print('  OK Architecture=iphoneos-arm64e')

    if data is None:
        raise SystemExit('没找到 data.tar 载荷')

    binaries = []
    print('\n=== 载荷清单 ===')
    with load_tar(data) as tf:
        for member in tf.getmembers():
            if member.isdir():
                continue
            print('   %8d  %s' % (member.size, member.name))
            if '.dylib' in member.name or member.name.endswith('.bundle/DockScrollerPrefs'):
                binaries.append((member.name, tf.extractfile(member).read()))

    print('\n=== Mach-O 切片 ===')
    for name, blob in binaries:
        sl = macho_slices(blob)
        if not sl:
            print('  %s → 非 Mach-O / 未知' % name)
            continue
        names = [slice_name(ct, cs) for ct, cs, _ in sl]
        detail = ', '.join('cputype=0x%08x cpusubtype=%d' % (ct, cs & 0x00FFFFFF) for ct, cs, _ in sl)
        print('  %s → %s' % (name, names))
        print('     (%s)' % detail)
        if 'arm64e' not in names:
            print('  !! 缺少 arm64e 切片（注入 arm64e 进程会崩）')

    print('\n=== 关键字命中（UTF-8 / UTF-16LE 双编码）===')
    for kw in keywords:
        hits = ['%s=%d' % (n.split('/')[-1], 1 if has(b, kw) else 0) for n, b in binaries]
        print('  %-16s %s' % (kw, ' '.join(hits) if hits else '（无二进制可查）'))


if __name__ == '__main__':
    main()
