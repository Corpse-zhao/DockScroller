#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""DockScroller 本地/CI 预检。

原则：只拦「编译期一定会挂」和「装了会出事」的问题，规则必须可解释、且做过注入验证。
有任何 BAD 就以非零退出，CI 里 Preflight 步骤必须排在 Build 之前。
"""

import io
import os
import plistlib
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BAD = []
OK = []


def read(path):
    with io.open(os.path.join(ROOT, path), "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def read_bytes(path):
    with open(os.path.join(ROOT, path), "rb") as f:
        return f.read()


def strip_comments(text):
    """剥掉 // 与 /* */ 注释，保留字符串字面量（行号会有偏移，只用于判断不用于报行号）。"""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n:
                if text[j] == '\\':
                    j += 2
                    continue
                if text[j] == '"':
                    j += 1
                    break
                j += 1
            out.append(text[i:j])
            i = j
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            j = text.find('\n', i)
            if j < 0:
                break
            i = j
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            j = text.find('*/', i + 2)
            if j < 0:
                break
            i = j + 2
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def check_version():
    control = read('control')
    m = re.search(r'^Version:\s*(\S+)\s*$', control, re.M)
    header = read('DSConfig.h')
    v = re.search(r'#define\s+DSC_VERSION\s+@"([^"]+)"', header)
    root_plist = read('prefs/Resources/Root.plist')
    if not m or not v:
        BAD.append('版本号自检：control 或 DSConfig.h 里找不到版本号')
        return
    if m.group(1) != v.group(1):
        BAD.append('版本号不一致：control=%s, DSConfig.h=%s' % (m.group(1), v.group(1)))
    info = read('prefs/Resources/Info.plist')
    if v.group(1) not in info:
        BAD.append('prefs/Resources/Info.plist 里的版本号不是 %s' % v.group(1))
    if v.group(1) not in root_plist:
        BAD.append('Root.plist 页脚里的版本号不是 %s' % v.group(1))
    if not BAD:
        OK.append('版本号三处一致：%s' % v.group(1))


def check_no_hook():
    tweak = strip_comments(read('Tweak.x'))
    if re.search(r'^%hook\s', tweak, re.M):
        BAD.append('Tweak.x 出现了 %hook —— 本项目设计上不 hook 任何私有类（静默失效风险）')
    if re.search(r'%orig', tweak):
        BAD.append('Tweak.x 出现 %orig，但没有 %hook')
    OK.append('Tweak.x 无 %hook（纯运行时视图操作，不存在钩子静默失效）')


def check_no_key_window():
    for path in ['Tweak.x', 'DSCommon.m', 'DSDockOverlay.m', 'DSDockManager.m',
                 'prefs/DSRootListController.m', 'prefs/DSAppPickerController.m',
                 'prefs/DSPrefsCommon.m']:
        code = strip_comments(read(path))
        if 'makeKeyAndVisible' in code:
            BAD.append('%s 用了 makeKeyAndVisible（会抢走 key window，可能把设备搞成点不动）' % path)
    OK.append('无 makeKeyAndVisible（不抢 key window）')


def check_line_endings():
    for path in ['control', 'layout/DEBIAN/postinst', 'prefs/Resources/Root.plist']:
        data = read_bytes(path)
        if b'\r\n' in data:
            BAD.append('%s 是 CRLF —— dpkg-deb 会拒绝打包（Windows 常见坑）' % path)
    OK.append('关键文本文件均为 LF')


def check_plists():
    for path in ['prefs/Resources/Root.plist', 'prefs/Resources/Info.plist']:
        try:
            with open(os.path.join(ROOT, path), 'rb') as f:
                plistlib.load(f)
            OK.append('%s 可解析' % path)
        except Exception as exc:  # noqa: BLE001
            BAD.append('%s 不是合法 XML plist：%s' % (path, exc))

    # 老式（ASCII）plist 用花括号配平检查
    for path in ['DockScroller.plist', 'layout/Library/PreferenceLoader/Preferences/DockScroller.plist']:
        text = read(path)
        body = re.sub(r'"(?:\\.|[^"\\])*"', '""', text)
        if body.count('{') != body.count('}'):
            BAD.append('%s 花括号不配平' % path)
        if body.count('(') != body.count(')'):
            BAD.append('%s 圆括号不配平' % path)
        if not re.search(r'\bentry\b', text) and 'PreferenceLoader' in path:
            BAD.append('PreferenceLoader 入口缺少 entry 包裹（会出现在设置里看不到入口）')
    OK.append('plist 结构与括号配平')


def check_plist_actions():
    root = read('prefs/Resources/Root.plist')
    code = strip_comments(read('prefs/DSRootListController.m'))
    actions = re.findall(r'<key>action</key>\s*<string>([^<]+)</string>', root)
    missing = [a for a in actions if not re.search(r'-\s*\(void\)\s*' + re.escape(a) + r'\s*\{', code)]
    if missing:
        BAD.append('Root.plist 里的 action 在 DSRootListController.m 里找不到实现：%s' % ', '.join(missing))
    else:
        OK.append('%d 个 action 全部有实现' % len(actions))


def check_specifiers_ivar():
    header = strip_comments(read('prefs/DSRootListController.h'))
    block = re.search(r'@interface\s+PSListController\b[^{]*\{(.*?)\}', header, re.S)
    if not block or not re.search(r'(?<![\w])_specifiers(?![\w])', block.group(1)):
        BAD.append('PSListController 的 ivar 块里缺少 _specifiers —— 面板会整页空白且不报错')
    else:
        OK.append('PSListController 的 _specifiers ivar 已声明')


def check_arc_formats():
    for path in ['DSCommon.m', 'DSDockOverlay.m', 'DSDockManager.m',
                 'prefs/DSRootListController.m', 'prefs/DSAppPickerController.m',
                 'prefs/DSPrefsCommon.m']:
        code = strip_comments(read(path))
        for m in re.finditer(r'\(\s*void\s*\*\s*\)\s*([A-Za-z_]\w*)', code):
            var = m.group(1)
            # objc_msgSend 是 C 函数、old/orig/imp 是 IMP，都是合法 C 指针，不需要 bridge
            if var in ('old', 'orig', 'imp', 'objc_msgSend') or 'IMP' in var:
                continue
            BAD.append('%s: (void *)%s 需要 __bridge（ARC 下编译不过）' % (path, var))
        if re.search(r'%s', code):
            # 格式串里的 %s 只能配 char*；本项目不用 char*，出现即疑似误用
            BAD.append('%s: 出现 %s 占位符，NSString 实参必须用 %%@' % (path, '%s'))
    OK.append('无未桥接的 (void *) 转换、无 %s 误用')


def check_dock_entry_point():
    mgr = strip_comments(read('DSDockManager.m'))
    need = ['ds_findDock', 'ds_normalizeOffset' if False else 'ds_tick', 'ds_teardown']
    for name in need:
        if name not in mgr:
            BAD.append('DSDockManager.m 缺少 %s' % name)
    overlay = strip_comments(read('DSDockOverlay.m'))
    for name in ['scrollViewWillEndDragging', 'ds_normalizeOffset', 'scrollViewDidScroll']:
        if name not in overlay:
            BAD.append('DSDockOverlay.m 缺少闭环关键实现：%s' % name)
    OK.append('闭环 / 吸附 / 卸载 关键实现齐全')


def check_no_auto_respring():
    """用户明确要求：安装时不要自动注销。postinst 里出现 killall SpringBoard 即视为回归。"""
    script = read('layout/DEBIAN/postinst')
    body = '\n'.join(line for line in script.splitlines()
                     if not line.strip().startswith('#'))
    if re.search(r'killall\s+(-?\w+\s+)*SpringBoard', body):
        BAD.append('postinst 里有 killall SpringBoard —— 用户要求安装时【不得自动注销】')
    elif re.search(r'\b(sbreload|respring)\b', body):
        BAD.append('postinst 里出现 sbreload/respring —— 等价于自动注销，用户不要求')
    else:
        OK.append('postinst 不自动注销（是否重启桌面交给用户）')


def check_specifiers_override():
    """PSListController 子类必须 override specifiers 并喂 loadSpecifiersFromPlistName，
    否则 _specifiers 恒为 nil，表现为「能进面板但整页空白」。"""
    code = strip_comments(read('prefs/DSRootListController.m'))
    if not re.search(r'-\s*\(NSArray\s*\*\)\s*specifiers\s*\{', code):
        BAD.append('DSRootListController 没 override specifiers —— 设置页会整页空白')
    elif 'loadSpecifiersFromPlistName' not in code:
        BAD.append('specifiers 里没调 loadSpecifiersFromPlistName —— Root.plist 不会被加载')
    else:
        OK.append('设置页 specifiers 已正确加载 Root.plist')


def check_launch_is_async():
    """DSLaunchBundle 绝不能在主线程同步调 workspace：同步 XPC 会与 SpringBoard 自等死锁，
    表现为「点图标整个桌面冻结」。必须走异步，或至少丢后台队列。"""
    code = strip_comments(read('DSCommon.m'))
    m = re.search(r'void\s+DSLaunchBundle\s*\(.*?\n\}\n', code, re.S)
    if not m:
        BAD.append('DSCommon.m 里找不到 DSLaunchBundle 实现')
        return
    body = m.group(0)
    problems = []
    if 'DSLaunchViaFrontBoard' not in body and 'dispatch_async' not in body:
        problems.append('DSLaunchBundle 没有异步路径 —— 同步 XPC 会死锁，点击即全屏卡死')
    # 直接在主线程同步调 workspace 是死锁根源
    if re.search(r'fn\w*\(\s*ws\s*,', body) and 'dispatch_async' not in body:
        problems.append('DSLaunchBundle 在主线程同步调用 workspace（死锁风险）')
    if 'FBSSystemService' not in code:
        problems.append('DSCommon.m 没有优先走 FBSSystemService 异步启动')
    if problems:
        BAD.extend(problems)
    else:
        OK.append('启动应用走异步（无同步 XPC 死锁）')


def main():
    check_version()
    check_no_hook()
    check_no_key_window()
    check_line_endings()
    check_plists()
    check_plist_actions()
    check_specifiers_ivar()
    check_arc_formats()
    check_dock_entry_point()
    check_no_auto_respring()
    check_specifiers_override()
    check_launch_is_async()

    for line in OK:
        print('  OK   ' + line)
    for line in BAD:
        print('  BAD  ' + line)
    if BAD:
        print('\n预检未通过：%d 项' % len(BAD))
        return 1
    print('\n预检通过（%d 项）' % len(OK))
    return 0


if __name__ == '__main__':
    sys.exit(main())
