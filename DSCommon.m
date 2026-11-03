//
//  DSCommon.m
//  DockScroller —— 插件端公共能力实现
//
//  设计要点（都是踩过的坑换来的）：
//  1. 全程 ARC（Makefile 里 -fobjc-arc），避免 MRC 下「便利构造器 + release」造成僵尸对象。
//  2. 私有 API 一律「运行时探测 + 失败降级 + 日志自证」，绝不硬调。
//  3. 不写 @try/@catch（Logos 对部分编译单元会吃掉 @catch，见技能库 §45）。
//  4. 配置读取做 1 秒缓存：tick 每秒一次，不能每次都同步读盘。
//

#import "DSCommon.h"
#import "DSConfig.h"

#pragma mark - 版本

NSString *DSCVersion(void) {
    return DSC_VERSION;
}

#pragma mark - 日志

// 三个候选落点：共享目录（postinst 已 777）→ 自身容器 tmp → /tmp
static NSString *DSLogPath(void) {
    static NSString *cached = nil;
    static BOOL resolved = NO;
    if (resolved) return cached;
    resolved = YES;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *dirs = @[ DSC_CONFIG_DIR, NSTemporaryDirectory(), @"/tmp" ];
    for (NSString *dir in dirs) {
        if (dir.length == 0) continue;
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *path = [dir stringByAppendingPathComponent:@"dock.log"];
        if ([fm fileExistsAtPath:path]) { cached = path; break; }
        if ([@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
            cached = path;
            break;
        }
    }
    return cached;
}

void DSLog(NSString *fmt, ...) {
    if (fmt.length == 0) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (body.length == 0) body = @"(空)";

    NSLog(@"[DockScroller] %@", body);

    NSString *path = DSLogPath();
    if (path.length == 0) return;

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], body];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attr = [fm attributesOfItemAtPath:path error:NULL];
    unsigned long long size = [attr fileSize];
    if (size > 256ULL * 1024ULL) {
        // 超过 256KB 整份重写，避免日志无限膨胀（用户设备上不会自行轮转）
        [data writeToFile:path atomically:YES];
        return;
    }
    if (![fm isWritableFileAtPath:path]) return;
    NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingAtPath:path];
    if (!handle) return;
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle closeFile];
}

#pragma mark - 保险丝

BOOL DSJailbreakDisabled(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:DSC_DISABLED_FILE]) return YES;
    if ([fm fileExistsAtPath:DSC_DISABLED_FILE2]) return YES;
    return NO;
}

#pragma mark - 配置

static NSDictionary *gCfg = nil;
static CFAbsoluteTime gCfgAt = 0.0;
static NSString *gCfgSource = @"none";

// 读取策略：先取 prefs 域，再用 config.plist 覆盖（面板两处都写，谁成功读谁）
static NSDictionary *DSConfigDict(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gCfg && (now - gCfgAt) < 1.0) return gCfg;
    gCfgAt = now;

    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    NSString *source = @"none";

    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:DSC_DOMAIN];
    if (ud) {
        for (NSString *key in @[ DSC_KEY_ENABLED, DSC_KEY_APPS, DSC_KEY_PER_PAGE, DSC_KEY_BANNER ]) {
            id v = [ud objectForKey:key];
            if (v) merged[key] = v;
        }
        if (merged.count) source = @"defaults";
    }

    NSDictionary *fileDict = [NSDictionary dictionaryWithContentsOfFile:DSC_CONFIG_FILE];
    if ([fileDict isKindOfClass:[NSDictionary class]] && fileDict.count) {
        [merged addEntriesFromDictionary:fileDict];
        source = merged.count > fileDict.count ? @"defaults+file" : @"file";
    }

    gCfg = [merged copy];
    gCfgSource = source;
    return gCfg ?: @{};
}

id DSCValue(NSString *key) {
    if (key.length == 0) return nil;
    return DSConfigDict()[key];
}

BOOL DSCBool(NSString *key, BOOL def) {
    id v = DSCValue(key);
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    return def;
}

NSInteger DSCInt(NSString *key, NSInteger def) {
    id v = DSCValue(key);
    if ([v respondsToSelector:@selector(integerValue)]) return [v integerValue];
    return def;
}

NSString *DSCConfigSource(void) {
    DSConfigDict();
    return gCfgSource;
}

#pragma mark - 私有 API 小工具

static NSString *DSStringProp(id obj, NSString *selName) {
    if (!obj || selName.length == 0) return nil;
    SEL sel = NSSelectorFromString(selName);
    if (![obj respondsToSelector:sel]) return nil;
    id v = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static id DSWorkspace(void) {
    Class cls = objc_getClass("LSApplicationWorkspace");
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(@"defaultWorkspace");
    if (![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
}

#pragma mark - 应用清单

NSArray<NSDictionary *> *DSInstalledUserApps(void) {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];

    id ws = DSWorkspace();
    if (!ws) {
        DSLog(@"[应用] 拿不到 LSApplicationWorkspace（无法枚举应用）");
        return out;
    }
    SEL sel = NSSelectorFromString(@"allInstalledApplications");
    if (![ws respondsToSelector:sel]) {
        DSLog(@"[应用] LSApplicationWorkspace 不支持 allInstalledApplications");
        return out;
    }
    NSArray *(*fn)(id, SEL) = (NSArray *(*)(id, SEL))objc_msgSend;
    NSArray *proxies = fn(ws, sel);
    if (![proxies isKindOfClass:[NSArray class]]) {
        DSLog(@"[应用] allInstalledApplications 返回非数组");
        return out;
    }

    for (id proxy in proxies) {
        NSString *type = DSStringProp(proxy, @"applicationType");
        if (type.length && ![type isEqualToString:@"User"]) continue;

        NSString *bid = DSStringProp(proxy, @"bundleIdentifier");
        if (bid.length == 0) bid = DSStringProp(proxy, @"applicationIdentifier");
        if (bid.length == 0) continue;

        NSString *name = DSStringProp(proxy, @"localizedName");
        if (name.length == 0) name = DSStringProp(proxy, @"itemName");
        if (name.length == 0) name = bid;

        [out addObject:@{ @"id": bid, @"name": name }];
    }

    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    DSLog(@"[应用] 枚举到 %lu 个用户应用", (unsigned long)out.count);
    return out;
}

#pragma mark - 启动应用

void DSLaunchBundle(NSString *bundleID) {
    if (bundleID.length == 0) return;

    id ws = DSWorkspace();
    if (!ws) {
        DSLog(@"[启动] %@ 失败：拿不到 workspace", bundleID);
        return;
    }

    SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:");
    if ([ws respondsToSelector:sel]) {
        BOOL (*fn)(id, SEL, NSString *) = (BOOL (*)(id, SEL, NSString *))objc_msgSend;
        BOOL ok = fn(ws, sel, bundleID);
        DSLog(@"[启动] %@ → %@", bundleID, ok ? @"已发起" : @"被拒绝");
        if (ok) return;
    }

    // 兜底：新版 workspace 的 options 变体
    SEL sel2 = NSSelectorFromString(@"openApplicationWithBundleID:options:configuration:error:");
    if ([ws respondsToSelector:sel2]) {
        BOOL (*fn2)(id, SEL, NSString *, id, id, NSError **) =
            (BOOL (*)(id, SEL, NSString *, id, id, NSError **))objc_msgSend;
        NSError *err = nil;
        BOOL ok = fn2(ws, sel2, bundleID, nil, nil, &err);
        DSLog(@"[启动] %@ 兜底路径 → %@ %@", bundleID, ok ? @"已发起" : @"失败", err.localizedDescription ?: @"");
    }
}

#pragma mark - 图标

static NSMutableDictionary<NSString *, UIImage *> *gIconCache = nil;

static UIImage *DSPlaceholderIcon(NSString *key, CGFloat size) {
    if (size < 8.0) size = 8.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect rect = CGRectMake(0, 0, size, size);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:size * 0.22];
        [[UIColor colorWithWhite:0.32 alpha:1.0] setFill];
        [path fill];

        NSString *letter = key.length ? [[key substringToIndex:1] uppercaseString] : @"?";
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:size * 0.46 weight:UIFontWeightSemibold],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.92]
        };
        CGSize ts = [letter sizeWithAttributes:attrs];
        [letter drawAtPoint:CGPointMake((size - ts.width) / 2.0, (size - ts.height) / 2.0) withAttributes:attrs];
    }];
    return img;
}

UIImage *DSIconForBundle(NSString *bundleID, CGFloat size) {
    if (bundleID.length == 0) return DSPlaceholderIcon(@"?", size);
    if (!gIconCache) gIconCache = [NSMutableDictionary dictionary];

    UIImage *cached = gIconCache[bundleID];
    if (cached) return cached;

    UIImage *img = nil;
    Class uiImageClass = [UIImage class];

    // 路径 1：UIKit 私有 API（SpringBoard / 设置进程内都可用）
    SEL sel1 = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([uiImageClass respondsToSelector:sel1]) {
        UIImage *(*fn1)(id, SEL, NSString *, NSInteger, CGFloat) =
            (UIImage *(*)(id, SEL, NSString *, NSInteger, CGFloat))objc_msgSend;
        img = fn1(uiImageClass, sel1, bundleID, 0, 0.0);
    }

    // 路径 2：老版本签名（无 scale）
    if (!img) {
        SEL sel2 = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:");
        if ([uiImageClass respondsToSelector:sel2]) {
            UIImage *(*fn2)(id, SEL, NSString *, NSInteger) =
                (UIImage *(*)(id, SEL, NSString *, NSInteger))objc_msgSend;
            img = fn2(uiImageClass, sel2, bundleID, 0);
        }
    }

    // 路径 3：LaunchServices 的图标数据
    if (!img) {
        Class proxyClass = objc_getClass("LSApplicationProxy");
        SEL selProxy = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (proxyClass && [proxyClass respondsToSelector:selProxy]) {
            id (*fnP)(id, SEL, NSString *) = (id (*)(id, SEL, NSString *))objc_msgSend;
            id proxy = fnP(proxyClass, selProxy, bundleID);
            SEL selData = NSSelectorFromString(@"iconDataForVariant:");
            if (proxy && [proxy respondsToSelector:selData]) {
                NSData *(*fnD)(id, SEL, NSInteger) = (NSData *(*)(id, SEL, NSInteger))objc_msgSend;
                NSData *data = fnD(proxy, selData, 2);
                if (![data isKindOfClass:[NSData class]] || data.length == 0) data = fnD(proxy, selData, 0);
                if ([data isKindOfClass:[NSData class]] && data.length) img = [UIImage imageWithData:data];
            }
        }
    }

    if (!img) {
        img = DSPlaceholderIcon(bundleID, MAX(size, 96.0));
        DSLog(@"[图标] %@ 三条路径都失败 → 用占位图", bundleID);
    }
    if (img) gIconCache[bundleID] = img;
    return img;
}
