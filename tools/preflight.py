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
    if not m or not v:
        BAD.append('版本号自检：control 或 DSConfig.h 里找不到版本号')
        return
    if m.group(1) != v.group(1):
        BAD.append('版本号不一致：control=%s, DSConfig.h=%s' % (m.group(1), v.group(1)))
    info = read('prefs/Resources/Info.plist')
    if v.group(1) not in info:
        BAD.append('prefs/Resources/Info.plist 里的版本号不是 %s' % v.group(1))
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
    for path in ['control', 'layout/DEBIAN/postinst']:
        data = read_bytes(path)
        if b'\r\n' in data:
            BAD.append('%s 是 CRLF —— dpkg-deb 会拒绝打包（Windows 常见坑）' % path)
    OK.append('关键文本文件均为 LF')


def check_plists():
    for path in ['prefs/Resources/Info.plist']:
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


PANEL_ACTIONS = ['openAppPicker', 'fillAll', 'clearAll', 'pickPerPage',
                 'pickIconSize', 'pickSpacing', 'showSelfCheck', 'showLog', 'respring']


def check_panel_actions():
    """自绘面板：每个 action 必须在 DSRootListController.m 里有对应方法实现。"""
    code = strip_comments(read('prefs/DSRootListController.m'))
    missing = [a for a in PANEL_ACTIONS
               if not re.search(r'-\s*\(void\)\s*' + re.escape(a) + r'\s*\{', code)]
    if missing:
        BAD.append('面板 action 在 DSRootListController.m 里找不到实现：%s' % ', '.join(missing))
    else:
        OK.append('%d 个面板 action 全部有实现' % len(PANEL_ACTIONS))


def check_hud_decoupled_from_switch():
    """状态横条必须【不受总开关控制】，并且在「关掉 / 没选应用」的提前返回之前就更新。

    原因：之前整页只有「Dock 有没有变成轮播」这一个现象可用，
    「插件没被注入」和「插件跑了但开关是关的」在桌面上完全一样，
    只能靠一轮轮试版本猜。横条脱钩之后，桌面上就能直接读出事实。
    """
    code = strip_comments(read('DSDockManager.m'))
    problems = []
    if 'ds_updateHUDInWindow' not in code:
        problems.append('没有状态横条实现（ds_updateHUDInWindow）')

    hud_at = code.find('ds_updateHUDInWindow:nil')
    early_at = code.find('if (!enabled || apps.count == 0)')
    if hud_at < 0:
        problems.append('ds_tick 里没有调用状态横条（应该每 tick 都更新）')
    elif early_at > 0 and hud_at > early_at:
        problems.append('状态横条写在提前返回之后 —— 开关一关就看不到，失去诊断意义')

    if problems:
        BAD.extend(problems)
    else:
        OK.append('状态横条与总开关解耦（关掉时也能看出插件是否在跑）')


def check_switch_write_verified():
    """总开关的写入必须「写 + 回读自证」，失败要能反馈给用户。

    以前的写法是写完就当成功，于是「拨了没落盘」只能表现为玄学：
    开关自己弹回 / 回桌面又关掉。
    """
    code = strip_comments(read('prefs/DSPrefsCommon.m'))
    panel = strip_comments(read('prefs/DSRootListController.m'))
    problems = []
    if not re.search(r'\bBOOL\s+DSPSetEnabledFlag\s*\(', code):
        problems.append('DSPSetEnabledFlag 没有返回写入结果（无法知道有没有落盘）')
    if 'DSPEnabledFlag(!on)' not in code:
        problems.append('DSPSetEnabledFlag 写完没有回读自证')
    if 'DSPSetEnabledFlag' not in panel:
        problems.append('面板没走 state 文件写入（setPreferenceValue 里找不到 DSPSetEnabledFlag）')
    # 绝不能再按「前台/后台」丢写入：这个守卫被写过两次，两次都让开关失效
    # （v0.1.7 用 viewIfLoaded.window 恒为 nil；v0.1.8 用 viewDidDisappear 打标记）。
    if '_dsVisible' in panel or 'viewIfLoaded.window' in panel:
        problems.append('面板又在按前台/后台拦截写入 —— 会让开关「拨开→退出→变关」')
    if 'viewDidDisappear' in panel:
        problems.append('面板又在 viewDidDisappear 里改写入条件（历史回归点）')
    if 'DSC_STATE_FILE2' not in code:
        problems.append('总开关只写一条通道（应双通道写入，任一条成功即可）')

    if problems:
        BAD.extend(problems)
    else:
        OK.append('总开关：双通道写 + 回读自证 + 不按前台/后台丢写入')


def check_no_editable_cell_keys():
    """手工构造的 specifier 不能挂「编辑框」系的键。

    真机反馈「其他功能多出来一个输入光标」：给 specifier 设 cell 字符串属性、
    或挂 cellTarget/cellSetter/cellGetter，会让框架走可编辑 cell 那条分支，
    结果按钮变成带光标的文本框，开关也拨不动。
    权威来源是 cellType，多余的键一律不设。
    """
    panel = strip_comments(read('prefs/DSRootListController.m'))
    problems = []
    for key in ['forKey:@"cell"', 'setCellTarget:', 'setCellSetter:', 'setCellGetter:']:
        if key in panel:
            problems.append('面板给 specifier 挂了 %s —— 会变成可编辑文本框（多出输入光标）' % key)
    # 反过来：开关必须有 getter，否则 cell 复用时会显示「构建时快照」的旧值
    if 'setGetter:' not in panel and 'forKey:@"getter"' not in panel:
        problems.append('开关没挂 getter —— cell 复用后显示旧状态（退出再进又变回关）')
    # 挂了 setter 会绕过 setPreferenceValue:，写盘 + 回读自证全部失效
    if 'setSetter:' in panel or 'forKey:@"setter"' in panel:
        problems.append('开关挂了 setter —— 会绕过我们的写盘逻辑')
    if problems:
        BAD.extend(problems)
    else:
        OK.append('specifier：不挂编辑框键、开关挂 getter 且不挂 setter')


def check_dock_position_memory():
    """点开 App 再退出，Dock 必须停在原地。

    轮播层在转场期间会被拆掉重建，重建时若把 offset 归位到第二份开头，
    表现为「每次退出 App 都被踢回第一页」。必须记位置 + 恢复。
    """
    overlay = strip_comments(read('DSDockOverlay.m'))
    overlay_h = strip_comments(read('DSDockOverlay.h'))
    manager = strip_comments(read('DSDockManager.m'))
    problems = []
    if 'ds_logicalOffset' not in overlay_h:
        problems.append('轮播层没有暴露当前位置（ds_logicalOffset）')
    if 'ds_restoreLogical' not in overlay_h:
        problems.append('轮播层没有恢复入口（ds_restoreLogical）')
    if 'ds_restoreLogical' not in overlay:
        problems.append('重建时没有使用位置记忆')
    if 'ds_logicalOffset' not in manager:
        problems.append('卸载前没有保存位置（DSDockManager 里找不到 ds_logicalOffset）')

    if problems:
        BAD.extend(problems)
    else:
        OK.append('位置记忆：重建 / 重装轮播层后回到原处（退出 App 不掉回第一页）')


def check_cell_type_values():
    """cellType 常量必须对得上 Preferences 的 PSCellType 枚举。

    真机踩过：DS_CELL_BUTTON 写成 8，而 8 是 PSEditTextCell（可编辑文本框），
    于是面板里每个按钮都变成带光标的输入框，点不动也存不了 ——
    用户看到的就是「多出来一个输入光标」「功能全废」。
    PSButtonCell = 13。
    """
    panel = strip_comments(read('prefs/DSRootListController.m'))
    expect = {'DS_CELL_GROUP': 0, 'DS_CELL_SWITCH': 6, 'DS_CELL_BUTTON': 13}
    problems = []
    for name, want in expect.items():
        m = re.search(r'#define\s+' + name + r'\s+(\d+)', panel)
        if not m:
            problems.append('找不到 %s 定义' % name)
        elif int(m.group(1)) != want:
            problems.append('%s = %s，应为 %d%s' % (
                name, m.group(1), want,
                '（8 是 PSEditTextCell，会变成带光标的输入框）' if want == 13 else ''))
    if problems:
        BAD.extend(problems)
    else:
        OK.append('cellType 数值正确（PSButtonCell=13，不会渲染成输入框）')


def check_no_disabled_fuse():
    """DISABLED 急救标记机制不得回归。

    「文件存在 = 插件停用」是单点死锁：删不掉就永远开不了，
    而且 SpringBoard 启动直接 return，表现为「插件完全不生效」。
    """
    problems = []
    for path in ['DSCommon.m', 'prefs/DSPrefsCommon.m', 'prefs/DSRootListController.m']:
        code = strip_comments(read(path))
        # 只允许 postinst 里做清理（rm -f），代码里不许再读写这个标记
        if re.search(r'fileExistsAtPath:\s*DSC_DISABLED_FILE', code):
            problems.append('%s 仍在读 DISABLED 标记（会造成永久停用）' % path)
    if 'define DSC_DISABLED_FILE' in read('DSConfig.h'):
        problems.append('DSConfig.h 又把 DISABLED 宏加回来了')
    if problems:
        BAD.extend(problems)
    else:
        OK.append('无 DISABLED 单点死锁机制（停用只走总开关）')


def check_enabled_priority_consistency():
    """两端读总开关必须是同一套规则：state 双通道（mtime 裁决）→ prefs 域 → config。

    「任一来源说关就是关」被真机证伪过：一条通道残留 NO 就永久锁死开关。
    """
    common = strip_comments(read('DSCommon.m'))
    prefs = strip_comments(read('prefs/DSPrefsCommon.m'))
    problems = []

    def body_of(code, func):
        start = code.find(func)
        if start < 0:
            return ''
        end = code.find('\n}\n', start)
        return code[start:end if end > 0 else len(code)]

    for label, code, func, reader in (('DSCommon.m', common, 'BOOL DSEnabledFlag(', 'DSReadState('),
                                      ('DSPrefsCommon.m', prefs, 'BOOL DSPEnabledFlag(', 'DSPReadState(')):
        if reader not in code:
            problems.append('%s 没有双通道 state 读取（%s）' % (label, reader))
            continue
        body = body_of(code, func)
        i_state = body.find(reader)
        i_pref = body.find('DSPrefsValue(')
        i_file = body.find('DSC_CONFIG_FILE')
        if i_state < 0:
            problems.append('%s 的开关函数没有先读 state（顺序不对）' % label)
        elif i_pref > 0 and i_state > i_pref:
            problems.append('%s 里 prefs 域排到了 state 前面（旧值会压住新值）' % label)
        elif i_file > 0 and i_state > i_file:
            problems.append('%s 里 config.plist 排到了 state 前面（顺序不对）' % label)

    # mtime 裁决必须存在，否则两条通道谁优先又变成硬编码
    for label, code in (('DSCommon.m', common), ('DSPrefsCommon.m', prefs)):
        if 'NSFileModificationDate' not in code:
            problems.append('%s 没有按修改时间裁决两条通道（旧值会压住新值）' % label)

    if problems:
        BAD.extend(problems)
    else:
        OK.append('总开关两端同规则：state 双通道按 mtime 裁决 → prefs 域 → config')


def check_panel_is_selfdrawn():
    """设置面板的三条硬约束（三条都是真机崩出来的）：
       a) 必须继承 PSListController —— OneSettings 会无保护调 setSpecifier:，
          纯 UIViewController 直接 unrecognized selector 崩；
       b) 不能重写 loadView —— 抢走基类的 table，基类任何回调都会把普通 UIView
          当 UITableView 用，两种入口全崩；
       c) 不能靠 loadSpecifiersFromPlistName: 读 plist —— 收纳插件不装配
          PSBundle 上下文，找不到 plist，页面空白且不报错。
       解法：用基类的 table 与生命周期，specifier 内存里手工构造。"""
    header = strip_comments(read('prefs/DSRootListController.h'))
    code = strip_comments(read('prefs/DSRootListController.m'))

    problems = []
    if not re.search(r'@interface\s+DSRootListController\s*:\s*PSListController', header):
        problems.append('面板没有继承 PSListController —— OneSettings 调 setSpecifier: 会打崩设置')
    if re.search(r'-\s*\(void\)\s*loadView\s*\{', code):
        problems.append('面板重写了 loadView —— 抢走基类 table 后基类回调必崩')
    if 'loadSpecifiersFromPlistName' in code:
        problems.append('面板用 loadSpecifiersFromPlistName: 读 plist —— 收纳插件下会空白')
    if 'preferenceSpecifierNamed' not in code:
        problems.append('面板没有手工构造 specifier（缺 preferenceSpecifierNamed 工厂调用）')

    if problems:
        BAD.extend(problems)
    else:
        OK.append('面板：PS 类身份 + 基类 table + specifier 手工构造（原生与收纳都可用）')


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
    """specifiers 必须 override 并返回手工构造的数组，否则基类拿去的是 nil/空 → 空白。"""
    code = strip_comments(read('prefs/DSRootListController.m'))
    if not re.search(r'-\s*\(NSArray\s*\*\)\s*specifiers\s*\{', code):
        BAD.append('DSRootListController 没 override specifiers —— 面板会整页空白')
    elif '_specifiers' not in code:
        BAD.append('specifiers 里没有存进 _specifiers（基类数据源取不到）')
    else:
        OK.append('specifiers 已 override 并手工构造（不依赖 plist）')


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


def check_scroll_only_when_needed():
    """用户要求：所选应用数 ≤ 每页图标数时不能滑动（一屏放得下就没必要滚）。"""
    code = strip_comments(read('DSDockOverlay.m'))
    if 'scrollEnabled' not in code:
        BAD.append('DSDockOverlay.m 没有按「应用数 ≤ 每页数」禁用滑动')
    elif not re.search(r'count\s*>\s*\(NSUInteger\)_perPage', code):
        BAD.append('缺少「应用数 > 每页数 才允许滑动」的判断')
    else:
        OK.append('应用数 ≤ 每页数时禁用滑动（不会出现无意义闭环）')


def check_panel_specifier_enabled():
    """手工构造的 specifier 必须显式 enabled=YES，否则框架按 NO 处理，
    表现就是「面板出来了但整页是暗的、点不动」。"""
    code = strip_comments(read('prefs/DSRootListController.m'))
    if 'forKey:@"enabled"' not in code:
        BAD.append('specifier 没设 enabled=YES —— 面板会整页变灰、点不动')
    elif 'forKey:@"key"' not in code:
        BAD.append('开关 specifier 没设 key —— PSSwitchCell 不知道读写哪个配置项')
    else:
        OK.append('specifier 显式 enabled=YES 且开关带 key（条目可点、开关可拨）')


def check_config_read_order():
    """Settings 进程里 NSUserDefaults(suiteName:) 写入未必落盘（cfprefsd 沙盒），
    而 config.plist 用普通文件 I/O 一定写得进去。
    所以读取必须「文件优先」——反过来会出现「开关拨一下就弹回去」。"""
    prefs = strip_comments(read('prefs/DSPrefsCommon.m'))
    m = re.search(r'BOOL\s+DSPBool\s*\(.*?\n\}\n', prefs, re.S)
    if not m:
        BAD.append('DSPrefsCommon.m 里找不到 DSPBool 实现')
        return
    body = m.group(0)
    i_file = body.find('DSPFileConfig()')
    i_ud = body.find('NSUserDefaults')
    if i_file < 0:
        BAD.append('DSPBool 没有读 config.plist')
    elif i_ud >= 0 and i_ud < i_file:
        BAD.append('DSPBool 先读 NSUserDefaults 再读 config.plist —— 开关会拨一下就弹回')
    else:
        OK.append('配置读取文件优先（开关不会弹回）')


def main():
    check_version()
    check_no_hook()
    check_no_key_window()
    check_line_endings()
    check_plists()
    check_plist_actions_placeholder = None  # 已由 check_panel_actions 取代
    del check_plist_actions_placeholder
    check_panel_actions()
    check_panel_is_selfdrawn()
    check_panel_specifier_enabled()
    check_switch_write_verified()
    check_hud_decoupled_from_switch()
    check_no_editable_cell_keys()
    check_cell_type_values()
    check_no_disabled_fuse()
    check_enabled_priority_consistency()
    check_dock_position_memory()
    check_config_read_order()
    check_arc_formats()
    check_dock_entry_point()
    check_scroll_only_when_needed()
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
