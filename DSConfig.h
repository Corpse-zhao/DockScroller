//
//  DSConfig.h
//  DockScroller —— 插件端与设置面板共用的常量（只放宏，不放符号）
//
//  ⚠️ 这里只能有 #define：tweak 与 prefs 是两个独立二进制，
//     任何函数符号都会让 prefs 出现「能编译、装上就崩」的跨目标引用。
//

#ifndef DS_CONFIG_H
#define DS_CONFIG_H

#define DSC_VERSION   @"0.1.13"
#define DSC_DOMAIN    @"com.cz.dockscroller"
#define DSC_NOTIFY    "com.cz.dockscroller.reload"

#define DSC_KEY_ENABLED    @"enabled"
#define DSC_KEY_APPS       @"apps"
#define DSC_KEY_PER_PAGE   @"perPage"
#define DSC_KEY_ICON_SIZE  @"iconSize"    // 负值 = 跟随系统 Dock 图标大小
#define DSC_KEY_SPACING    @"spacing"     // 负值 = 自动（图标在槽内居中）
#define DSC_KEY_BANNER     @"debugBanner"

// 每页图标数：用户要求「最多五个」
#define DSC_DEFAULT_PER_PAGE 4
#define DSC_MIN_PER_PAGE 1
#define DSC_MAX_PER_PAGE 5

// 负值哨兵：表示「交给系统 / 自动」
#define DSC_SIZE_AUTO (-1)

// 共享配置目录：postinst 里预建并 chmod 777，方便 Filza 查看与两进程读写
#define DSC_CONFIG_DIR     @"/var/mobile/Documents/DockScroller"
#define DSC_CONFIG_FILE    @"/var/mobile/Documents/DockScroller/config.plist"
#define DSC_LOG_FILE       @"/var/mobile/Documents/DockScroller/dock.log"

// ⚠️ DISABLED 急救标记机制【已废除】，不要再加回来。
//    曾经的实现是「文件存在 = 插件停用」，结果是单点死锁：
//    关一次 → 建了文件 → 之后「开」要删它，删不掉（沙盒）就永远开不了，
//    更糟的是 SpringBoard 启动时直接 return，表现为「插件完全不生效」。
//    现在停用只有一条路：总开关（prefs 域 + state 文件），可双向读写。

// 总开关的状态存储：两条【纯文件】通道，谁最后被写过就用谁。
//
// 为什么不用 NSUserDefaults / cfprefsd：那层缓存会让「写了」和「落盘了」
// 变成两件事，真机上表现为「拨开 → 退出 → 又变回关」，而且回读还能骗过自己。
// 为什么两条：/var/mobile/Documents 和 /var/mobile/Library/Preferences 在不同
// 越狱环境下可写性不一样，写两条只要有一条成功就够；读取时按文件修改时间裁决，
// 不需要预设哪个优先，避免「一条通道残留旧值把另一条压死」。
#define DSC_STATE_FILE     @"/var/mobile/Documents/DockScroller/state"
#define DSC_STATE_FILE2    @"/var/mobile/Library/Preferences/com.cz.dockscroller.state"

#endif /* DS_CONFIG_H */
