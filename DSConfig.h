//
//  DSConfig.h
//  DockScroller —— 插件端与设置面板共用的常量（只放宏，不放符号）
//
//  ⚠️ 这里只能有 #define：tweak 与 prefs 是两个独立二进制，
//     任何函数符号都会让 prefs 出现「能编译、装上就崩」的跨目标引用。
//

#ifndef DS_CONFIG_H
#define DS_CONFIG_H

#define DSC_VERSION   @"0.1.0"
#define DSC_DOMAIN    @"com.cz.dockscroller"
#define DSC_NOTIFY    "com.cz.dockscroller.reload"

#define DSC_KEY_ENABLED    @"enabled"
#define DSC_KEY_APPS       @"apps"
#define DSC_KEY_PER_PAGE   @"perPage"
#define DSC_KEY_BANNER     @"debugBanner"

#define DSC_DEFAULT_PER_PAGE 4

// 共享配置目录：postinst 里预建并 chmod 777，方便 Filza 查看与两进程读写
#define DSC_CONFIG_DIR     @"/var/mobile/Documents/DockScroller"
#define DSC_CONFIG_FILE    @"/var/mobile/Documents/DockScroller/config.plist"
#define DSC_LOG_FILE       @"/var/mobile/Documents/DockScroller/dock.log"
#define DSC_DISABLED_FILE  @"/var/mobile/Documents/DockScroller/DISABLED"
#define DSC_DISABLED_FILE2 @"/var/mobile/Library/Preferences/dockscroller.disabled"

#endif /* DS_CONFIG_H */
