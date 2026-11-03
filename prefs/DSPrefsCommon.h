//
//  DSPrefsCommon.h
//  设置面板侧（Preferences 进程）的本地工具。
//
//  ⚠️ 这里所有函数都在 prefs 二进制里【自己实现一份】：
//     面板是独立二进制、不加载插件 dylib，直接调插件端函数会「能编译、点开就崩」。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NSArray<NSString *> *DSPApps(void);
void DSPAppsSet(NSArray<NSString *> *apps);

NSInteger DSPInt(NSString *key, NSInteger def);
BOOL DSPBool(NSString *key, BOOL def);
void DSPSetInt(NSString *key, NSInteger value);
void DSPSetBool(NSString *key, BOOL value);

NSArray<NSDictionary *> *DSPInstalledUserApps(void);
UIImage *DSPIconForBundle(NSString *bundleID, CGFloat size);

NSString *DSPLogPath(void);
void DSPLog(NSString *fmt, ...);

// 重启桌面（roothide 沙盒里 posix_spawn/killall 会被静默拦截，只能自己枚举进程）
void DSPRespring(void);
