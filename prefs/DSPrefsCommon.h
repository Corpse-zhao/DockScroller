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

// 总开关：独立的纯文本状态文件（内容 "1"/"0"）。
// 返回 YES 表示「写进去了 + 回读一致」，调用方据此给用户明确反馈，
// 而不是写完就当成功（以前就是这样才出现「拨开又自己关」的假象）。
BOOL DSPEnabledFlag(BOOL def);
BOOL DSPSetEnabledFlag(BOOL on);
NSString *DSPStateRaw(void);   // state 文件原始内容，供「状态自检」展示

NSArray<NSDictionary *> *DSPInstalledUserApps(void);
UIImage *DSPIconForBundle(NSString *bundleID, CGFloat size);

NSString *DSPLogPath(void);
void DSPLog(NSString *fmt, ...);

// 重启桌面（roothide 沙盒里 posix_spawn/killall 会被静默拦截，只能自己枚举进程）
void DSPRespring(void);
