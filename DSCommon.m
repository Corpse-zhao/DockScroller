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

#pragma mark - 保险丝（已废弃）

// ⚠️ 保留函数只为兼容调用点，永远返回 NO。
//    「文件存在就停用」这套机制会造成单点死锁：文件删不掉就永远开不了，
//    而且 SpringBoard 启动时直接 return，真机上表现为「插件完全不生效」。
//    停用现在只走总开关一条路。
BOOL DSJailbreakDisabled(void) {
    return NO;
}

#pragma mark - 配置

// 读 prefs 域（Preferences 框架自己的 plist）。
// 这是设置面板与 SpringBoard 之间最可靠的一条通道 —— 原生开关存的就是这里。
static id DSPrefsValue(NSString *key) {
    if (key.length == 0) return nil;
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)DSC_DOMAIN);
    return v ? (__bridge_transfer id)v : nil;
}

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
        for (NSString *key in @[ DSC_KEY_ENABLED, DSC_KEY_APPS, DSC_KEY_PER_PAGE,
                                 DSC_KEY_ICON_SIZE, DSC_KEY_SPACING, DSC_KEY_BANNER ]) {
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

// 读两条 state 通道里「最后被修改」的那条 —— 用 mtime 裁决，不预设优先级。
// 这样某条通道被沙盒挡住、残留着旧值时，另一条新写的会自动胜出。
// 返回 nil 表示两条都没有可用值。
static NSString *DSReadState(BOOL *found) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *bestRaw = nil;
    NSDate *bestDate = nil;

    for (NSString *path in @[ DSC_STATE_FILE, DSC_STATE_FILE2 ]) {
        NSDictionary *attr = [fm attributesOfItemAtPath:path error:NULL];
        if (![attr isKindOfClass:[NSDictionary class]]) continue;

        NSString *raw = [NSString stringWithContentsOfFile:path
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
        if (![raw isKindOfClass:[NSString class]]) continue;
        raw = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (raw.length == 0) continue;

        NSDate *date = attr[NSFileModificationDate];
        if (![date isKindOfClass:[NSDate class]]) date = [NSDate distantPast];
        if (!bestDate || [date compare:bestDate] == NSOrderedDescending) {
            bestDate = date;
            bestRaw = raw;
        }
    }

    if (found) *found = (bestRaw != nil);
    return bestRaw;
}

// 总开关：state 双通道 → prefs 域 → config.plist → 默认值。
// ⚠️ 绝对不要再做成「任一来源说关就是关」：一条通道残留 NO 就会把开关钉死。
BOOL DSEnabledFlag(BOOL def) {
    BOOL found = NO;
    NSString *raw = DSReadState(&found);
    if (found) return [raw boolValue] || [raw isEqualToString:@"1"];

    id v = DSPrefsValue(DSC_KEY_ENABLED);
    if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];

    NSDictionary *fileDict = [NSDictionary dictionaryWithContentsOfFile:DSC_CONFIG_FILE];
    if ([fileDict isKindOfClass:[NSDictionary class]]) {
        v = fileDict[DSC_KEY_ENABLED];
        if ([v respondsToSelector:@selector(boolValue)]) return [v boolValue];
    }

    return def;
}

BOOL DSCBool(NSString *key, BOOL def) {
    if ([key isEqualToString:DSC_KEY_ENABLED]) return DSEnabledFlag(def);

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

// ⚠️ 死锁警告（v0.1.1 修的就是这个）：
//    -[LSApplicationWorkspace openApplicationWithBundleID:] 是【同步 XPC】。
//    在 SpringBoard 主线程上调它，lsd 收到请求后要让 SpringBoard 自己去执行转场，
//    而 SpringBoard 主线程正卡在等 lsd 返回 → 互等 → 全屏冻结，只能强制重启。
//
//    所以这里两件事一起做：
//      1) 首选 FBSSystemService 的 openApplication:options:withResult: —— 天生异步（block 回调）；
//      2) 兜底走 LSApplicationWorkspace，但一定丢到【后台串行队列】，
//         主线程立刻返回，再也不给死锁留机会。

static dispatch_queue_t DSLaunchQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.cz.dockscroller.launch", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static id DSFrontBoardService(void) {
    static Class cls = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // SpringBoard 进程里 FrontBoardServices 通常已加载，保险起见手动 dlopen
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
               RTLD_LAZY);
        cls = objc_getClass("FBSSystemService");
    });
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(@"sharedService");
    if (![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
}

// 兜底：同步 XPC，必须跑在后台队列上
static void DSLaunchViaWorkspaceAsync(NSString *bundleID);

// 第一优先：真正异步，不阻塞任何线程
static BOOL DSLaunchViaFrontBoard(NSString *bundleID) {
    id service = DSFrontBoardService();
    if (!service) return NO;

    SEL sel = NSSelectorFromString(@"openApplication:options:withResult:");
    if (![service respondsToSelector:sel]) return NO;

    typedef void (^DSOpenResultBlock)(NSError *);
    void (*fn)(id, SEL, NSString *, NSDictionary *, DSOpenResultBlock) =
        (void (*)(id, SEL, NSString *, NSDictionary *, DSOpenResultBlock))objc_msgSend;

    // 空选项最稳：带未知 key 可能被 FrontBoard 校验拒绝，表现为「点了没反应」
    fn(service, sel, bundleID, @{}, ^(NSError *error) {
        if (error) {
            DSLog(@"[启动] %@ FrontBoard 报错：%@ → 转后台 workspace 兜底", bundleID,
                  error.localizedDescription ?: @"未知错误");
            DSLaunchViaWorkspaceAsync(bundleID);
        } else {
            DSLog(@"[启动] %@ 已交给系统", bundleID);
        }
    });
    DSLog(@"[启动] %@ → FrontBoard 异步已发起", bundleID);
    return YES;
}

// 兜底：同步 XPC，必须跑在后台队列上
static void DSLaunchViaWorkspaceAsync(NSString *bundleID) {
    dispatch_async(DSLaunchQueue(), ^{
        @autoreleasepool {
            id ws = DSWorkspace();
            if (!ws) {
                DSLog(@"[启动] %@ 失败：拿不到 workspace", bundleID);
                return;
            }

            SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:");
            if ([ws respondsToSelector:sel]) {
                BOOL (*fn)(id, SEL, NSString *) = (BOOL (*)(id, SEL, NSString *))objc_msgSend;
                BOOL ok = fn(ws, sel, bundleID);
                DSLog(@"[启动] %@ → %@（后台线程）", bundleID, ok ? @"已发起" : @"被拒绝");
                if (ok) return;
            }

            SEL sel2 = NSSelectorFromString(@"openApplicationWithBundleID:options:configuration:error:");
            if ([ws respondsToSelector:sel2]) {
                BOOL (*fn2)(id, SEL, NSString *, id, id, NSError **) =
                    (BOOL (*)(id, SEL, NSString *, id, id, NSError **))objc_msgSend;
                NSError *err = nil;
                BOOL ok = fn2(ws, sel2, bundleID, nil, nil, &err);
                DSLog(@"[启动] %@ 兜底 → %@ %@", bundleID, ok ? @"已发起" : @"失败",
                      err.localizedDescription ?: @"");
            }
        }
    });
}

void DSLaunchBundle(NSString *bundleID) {
    if (bundleID.length == 0) return;

    // 主线程只做「登记 + 立刻返回」，绝不同步等待任何 XPC
    if (DSLaunchViaFrontBoard(bundleID)) return;

    DSLog(@"[启动] FrontBoard 不可用，改走后台 workspace 路径");
    DSLaunchViaWorkspaceAsync(bundleID);
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
