//
//  DSCommon.h
//  DockScroller —— 插件端公共能力（配置 / 日志 / 应用清单 / 启动 / 图标）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <dlfcn.h>

NSString *DSCVersion(void);

// 追加写日志（超 256KB 整份重写），最终落点见实现
void DSLog(NSString *fmt, ...);

// 用户手动放置的「保险丝」文件：存在则插件完全不启动
BOOL DSJailbreakDisabled(void);

// 配置
id          DSCValue(NSString *key);
BOOL        DSCBool(NSString *key, BOOL def);
NSInteger   DSCInt(NSString *key, NSInteger def);
// 总开关的权威读取（state 文件），tick 里直接用 DSCBool(DSC_KEY_ENABLED) 即可
BOOL        DSEnabledFlag(BOOL def);
NSString   *DSCConfigSource(void);

// 应用清单（已安装的用户应用，按名称排序，元素为 @{id, name}）
NSArray<NSDictionary *> *DSInstalledUserApps(void);

// 启动应用
void DSLaunchBundle(NSString *bundleID);

// 取应用图标（失败时给占位图，绝不返回 nil）
UIImage *DSIconForBundle(NSString *bundleID, CGFloat size);
