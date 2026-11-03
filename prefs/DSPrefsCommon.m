//
//  DSPrefsCommon.m
//  设置面板侧工具实现（与插件端逻辑同源，但符号完全独立）
//

#import "DSPrefsCommon.h"
#import "DSConfig.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <signal.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

// libproc 不在 iOS SDK 里，手动声明（Proc 相关函数实际在 libSystem）
extern int proc_listpids(int type, int typeinfo, void *buffer, int buffersize);
extern int proc_name(int pid, void *buffer, int buffersize);
#define DS_PROC_ALL_PIDS 1

#pragma mark - 配置

static NSDictionary *DSPFileConfig(void) {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:DSC_CONFIG_FILE];
    if ([dict isKindOfClass:[NSDictionary class]]) return dict;
    return @{};
}

static void DSPFileConfigWrite(NSString *key, id value) {
    if (key.length == 0 || !value) return;
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    [dict addEntriesFromDictionary:DSPFileConfig()];
    dict[key] = value;

    [[NSFileManager defaultManager] createDirectoryAtPath:DSC_CONFIG_DIR
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:NULL];
    [dict writeToFile:DSC_CONFIG_FILE atomically:YES];
}

NSArray<NSString *> *DSPApps(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];

    // 同样是文件优先，理由见 DSPInt 上方注释
    id raw = DSPFileConfig()[DSC_KEY_APPS];
    if (![raw isKindOfClass:[NSArray class]]) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:DSC_DOMAIN];
        raw = [defaults objectForKey:DSC_KEY_APPS];
    }
    if ([raw isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)raw) {
            if ([item isKindOfClass:[NSString class]] && [item length] > 0) [out addObject:item];
        }
    }
    return out;
}

void DSPAppsSet(NSArray<NSString *> *apps) {
    NSArray *safe = apps ?: @[];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:DSC_DOMAIN];
    [defaults setObject:safe forKey:DSC_KEY_APPS];
    [defaults synchronize];
    DSPFileConfigWrite(DSC_KEY_APPS, safe);

    // 立刻通知 SpringBoard 重读（不等它自己的 1 秒轮询）
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                        CFSTR(DSC_NOTIFY), NULL, NULL, true);
    DSPLog(@"[设置] 已保存 %lu 个应用", (unsigned long)safe.count);
}

// ⚠️ 读取顺序必须是「config.plist 优先，NSUserDefaults 兜底」。
//    原因：Settings 进程里 initWithSuiteName: 受 cfprefsd 沙盒限制，写入未必落盘，
//    而 config.plist 是普通文件 I/O，一定写得进去且立刻可读。
//    反过来（defaults 优先）会出现「开关拨一下就弹回去」——
//    因为读到的还是 defaults 里的旧值。
NSInteger DSPInt(NSString *key, NSInteger def) {
    id v = DSPFileConfig()[key];
    if (v == nil) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:DSC_DOMAIN];
        v = [defaults objectForKey:key];
    }
    if ([v respondsToSelector:@selector(integerValue)]) return [v integerValue];
    return def;
}

BOOL DSPBool(NSString *key, BOOL def) {
    id v = DSPFileConfig()[key];
    if (v == nil) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:DSC_DOMAIN];
        v = [defaults objectForKey:key];
    }
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return def;
}

void DSPSetInt(NSString *key, NSInteger value) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:DSC_DOMAIN];
    [defaults setInteger:value forKey:key];
    [defaults synchronize];
    DSPFileConfigWrite(key, @(value));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                        CFSTR(DSC_NOTIFY), NULL, NULL, true);
}

void DSPSetBool(NSString *key, BOOL value) {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:DSC_DOMAIN];
    [defaults setBool:value forKey:key];
    [defaults synchronize];
    DSPFileConfigWrite(key, @(value));
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                        CFSTR(DSC_NOTIFY), NULL, NULL, true);
}

#pragma mark - 私有 API 工具

static NSString *DSPStringProp(id obj, NSString *selName) {
    if (!obj || selName.length == 0) return nil;
    SEL sel = NSSelectorFromString(selName);
    if (![obj respondsToSelector:sel]) return nil;
    id v = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static id DSPWorkspace(void) {
    Class cls = objc_getClass("LSApplicationWorkspace");
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(@"defaultWorkspace");
    if (![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
}

NSArray<NSDictionary *> *DSPInstalledUserApps(void) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    id workspace = DSPWorkspace();
    if (!workspace) {
        DSPLog(@"[设置] 拿不到 LSApplicationWorkspace");
        return out;
    }
    SEL sel = NSSelectorFromString(@"allInstalledApplications");
    if (![workspace respondsToSelector:sel]) {
        DSPLog(@"[设置] 不支持 allInstalledApplications");
        return out;
    }
    NSArray *(*fn)(id, SEL) = (NSArray *(*)(id, SEL))objc_msgSend;
    NSArray *proxies = fn(workspace, sel);
    if (![proxies isKindOfClass:[NSArray class]]) return out;

    for (id proxy in proxies) {
        NSString *type = DSPStringProp(proxy, @"applicationType");
        if (type.length && ![type isEqualToString:@"User"]) continue;

        NSString *bid = DSPStringProp(proxy, @"bundleIdentifier");
        if (bid.length == 0) bid = DSPStringProp(proxy, @"applicationIdentifier");
        if (bid.length == 0) continue;

        NSString *name = DSPStringProp(proxy, @"localizedName");
        if (name.length == 0) name = DSPStringProp(proxy, @"itemName");
        if (name.length == 0) name = bid;

        [out addObject:@{ @"id": bid, @"name": name }];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return out;
}

UIImage *DSPIconForBundle(NSString *bundleID, CGFloat size) {
    if (bundleID.length == 0) return nil;
    UIImage *img = nil;
    Class imageClass = [UIImage class];

    SEL sel1 = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([imageClass respondsToSelector:sel1]) {
        UIImage *(*fn1)(id, SEL, NSString *, NSInteger, CGFloat) =
            (UIImage *(*)(id, SEL, NSString *, NSInteger, CGFloat))objc_msgSend;
        img = fn1(imageClass, sel1, bundleID, 0, 0.0);
    }
    if (!img) {
        SEL sel2 = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:");
        if ([imageClass respondsToSelector:sel2]) {
            UIImage *(*fn2)(id, SEL, NSString *, NSInteger) =
                (UIImage *(*)(id, SEL, NSString *, NSInteger))objc_msgSend;
            img = fn2(imageClass, sel2, bundleID, 0);
        }
    }
    if (!img) {
        Class proxyClass = objc_getClass("LSApplicationProxy");
        SEL proxySel = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (proxyClass && [proxyClass respondsToSelector:proxySel]) {
            id (*fnP)(id, SEL, NSString *) = (id (*)(id, SEL, NSString *))objc_msgSend;
            id proxy = fnP(proxyClass, proxySel, bundleID);
            SEL dataSel = NSSelectorFromString(@"iconDataForVariant:");
            if (proxy && [proxy respondsToSelector:dataSel]) {
                NSData *(*fnD)(id, SEL, NSInteger) = (NSData *(*)(id, SEL, NSInteger))objc_msgSend;
                NSData *data = fnD(proxy, dataSel, 2);
                if (![data isKindOfClass:[NSData class]] || data.length == 0) data = fnD(proxy, dataSel, 0);
                if ([data isKindOfClass:[NSData class]] && data.length) img = [UIImage imageWithData:data];
            }
        }
    }
    return img;
}

#pragma mark - 日志

NSString *DSPLogPath(void) {
    static NSString *cached = nil;
    static BOOL resolved = NO;
    if (resolved) return cached;
    resolved = YES;

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in @[ DSC_CONFIG_DIR, NSTemporaryDirectory() ]) {
        if (dir.length == 0) continue;
        NSString *path = [dir stringByAppendingPathComponent:@"dock.log"];
        if ([fm fileExistsAtPath:path] && [fm isReadableFileAtPath:path]) { cached = path; break; }
    }
    return cached;
}

void DSPLog(NSString *fmt, ...) {
    if (fmt.length == 0) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] [设置] %@\n", [df stringFromDate:[NSDate date]], body];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:DSC_CONFIG_DIR withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path = [DSC_CONFIG_DIR stringByAppendingPathComponent:@"dock.log"];
    if (![fm fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingAtPath:path];
    if (!handle) return;
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle closeFile];
}

#pragma mark - 重启桌面

void DSPRespring(void) {
    int count = proc_listpids(DS_PROC_ALL_PIDS, 0, NULL, 0);
    if (count <= 0) return;

    size_t bytes = (size_t)count * sizeof(pid_t);
    pid_t *pids = malloc(bytes);
    if (!pids) return;

    int got = proc_listpids(DS_PROC_ALL_PIDS, 0, pids, (int)bytes);
    if (got > 0) {
        int total = got / (int)sizeof(pid_t);
        for (int i = 0; i < total; i++) {
            pid_t pid = pids[i];
            if (pid <= 0) continue;
            char name[64] = {0};
            if (proc_name(pid, name, (int)sizeof(name)) <= 0) continue;
            if (strcmp(name, "SpringBoard") == 0) kill(pid, SIGKILL);
        }
    }
    free(pids);
}
