//
//  DSDockManager.m
//  DockScroller
//
//  为什么不 hook 私有类：Logos 对「类/方法不存在」是静默丢弃的（编译过、CI 绿、永远不执行），
//  而且 Dock 的私有类名跨版本会变。所以这里只用「运行时找视图 + 自绘」两件事。
//
//  为什么用 1 秒轮询而不是布局回调：布局回调里改视图树会造出不收敛的反馈环
//  （键盘插件踩过 8 次）。轮询天然避开，2.5Hz 的开销可忽略。
//

#import "DSDockManager.h"
#import "DSConfig.h"
#import "DSCommon.h"
#import "DSDockOverlay.h"
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

static char kDSOriginalAlphaKey;
static const CFTimeInterval kDSTickInterval = 1.0;

// 前置声明：ds_tick 里用到了定义在文件后部的这个函数
static NSArray<UIWindow *> *DSAllWindows(void);

@interface DSDockManager ()
- (void)ds_tick;
- (void)ds_forceRefresh;
@end

static void DSDockConfigChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)name; (void)object; (void)userInfo;
    DSDockManager *manager = (__bridge DSDockManager *)observer;
    if (manager) [manager ds_forceRefresh];
}

@implementation DSDockManager {
    DSDockOverlayView *_overlay;
    NSString *_signature;
    NSMutableArray<UIView *> *_hiddenIcons;
    NSTimer *_timer;
    UIButton *_banner;
    NSString *_bannerText;
    BOOL _bannerHiddenByUser;
    BOOL _loggedDockClasses;
    // 缓存：每秒全树扫描太重，命中过一次后就复用，失效才重扫
    __weak UIView *_cachedDock;
    __weak UIView *_hiddenDock;
    // 系统 Dock 里图标的真实边长（默认图标大小就取它，保证「和系统一样」）
    CGFloat _systemIconSize;
}

+ (instancetype)shared {
    static DSDockManager *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[DSDockManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _hiddenIcons = [NSMutableArray array];
    return self;
}

#pragma mark - 生命周期

- (void)start {
    if (_timer) return;

    if (DSJailbreakDisabled()) {
        DSLog(@"[自检] 发现 DISABLED 保险丝文件 → 插件不启动");
        return;
    }

    DSLog(@"[自检] Dock 轮播 %@ 启动（pid=%d，配置来源=%@）",
          DSCVersion(), (int)getpid(), DSCConfigSource());

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)(self),
                                    DSDockConfigChanged,
                                    CFSTR(DSC_NOTIFY),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    [self ds_tick];

    _timer = [NSTimer timerWithTimeInterval:kDSTickInterval
                                     target:self
                                   selector:@selector(ds_tick)
                                   userInfo:nil
                                    repeats:YES];
    // 放进 common modes，滚动/拖动时也继续跑（默认 mode 会停摆）
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)ds_forceRefresh {
    _signature = nil;
    [self ds_tick];
}

#pragma mark - 主循环

- (void)ds_tick {
    BOOL enabled = DSCBool(DSC_KEY_ENABLED, YES);
    NSInteger perPage = DSCInt(DSC_KEY_PER_PAGE, DSC_DEFAULT_PER_PAGE);
    if (perPage < DSC_MIN_PER_PAGE) perPage = DSC_MIN_PER_PAGE;
    if (perPage > DSC_MAX_PER_PAGE) perPage = DSC_MAX_PER_PAGE;
    CGFloat iconSize = (CGFloat)DSCInt(DSC_KEY_ICON_SIZE, DSC_SIZE_AUTO);
    CGFloat spacing = (CGFloat)DSCInt(DSC_KEY_SPACING, DSC_SIZE_AUTO);

    NSArray<NSString *> *apps = enabled ? [self ds_apps] : @[];

    // 关掉总开关、或没勾选任何应用 → 完全回到系统原生 Dock（覆盖层、横幅、隐藏的图标全部还原）
    if (!enabled || apps.count == 0) {
        [self ds_teardown];
        [_banner removeFromSuperview];
        _bannerText = nil;
        return;
    }

    UIView *dock = [self ds_findDock];

    if (!dock || !dock.window) {
        UIWindow *fallback = nil;
        for (UIWindow *candidate in DSAllWindows()) {
            if (candidate.isKeyWindow) { fallback = candidate; break; }
        }
        if (!fallback) {
            for (UIWindow *candidate in DSAllWindows()) {
                if (!candidate.hidden) { fallback = candidate; break; }
            }
        }
        if (fallback) {
            [self ds_attachBannerTo:fallback];   // 先挂上去，再写文案（否则第一次写入会丢）
            [self ds_updateBannerText:[NSString stringWithFormat:@"Dock 轮播 %@ · 等待桌面 Dock", DSCVersion()]];
        }
        return;
    }

    UIWindow *window = dock.window;
    CGRect frame = [dock convertRect:dock.bounds toView:window];
    if (frame.size.width < 40.0 || frame.size.height < 20.0) {
        [self ds_teardown];
        [self ds_updateBannerText:[NSString stringWithFormat:@"Dock 轮播 %@ · 区域异常", DSCVersion()]];
        return;
    }

    if (!_overlay) {
        _overlay = [[DSDockOverlayView alloc] initWithFrame:frame];
        [window addSubview:_overlay];
        DSLog(@"[Dock] 已安装轮播层：区域 %.0fx%.0f @ (%.0f, %.0f)",
              frame.size.width, frame.size.height, frame.origin.x, frame.origin.y);
    }
    if (!CGRectEqualToRect(_overlay.frame, frame)) _overlay.frame = frame;

    if (_overlay.superview != window) {
        [window addSubview:_overlay];
    } else if (window.subviews.lastObject != _overlay) {
        [window bringSubviewToFront:_overlay];
    }

    [self ds_hideSystemIconsIn:dock];

    NSString *signature = [NSString stringWithFormat:@"%ld|%.1f|%.1f|%.1f|%.1f|%@",
                           (long)perPage, frame.size.width, iconSize, spacing,
                           _systemIconSize,
                           [apps componentsJoinedByString:@","]];
    if (![_signature isEqualToString:signature]) {
        _signature = signature;
        [_overlay reloadWithApps:apps
                         perPage:perPage
                        iconSize:iconSize
                         spacing:spacing
                  systemIconSize:_systemIconSize];
        DSLog(@"[Dock] 应用 %lu 个 / 每页 %ld / 图标 %@ / 间距 %@",
              (unsigned long)apps.count, (long)perPage,
              (iconSize > 0.0 ? [NSString stringWithFormat:@"%.0f" , iconSize] : @"跟随系统"),
              (spacing >= 0.0 ? [NSString stringWithFormat:@"%.0f", spacing] : @"自动"));
    }

    [self ds_attachBannerTo:window];
    [self ds_updateBannerText:[NSString stringWithFormat:@"Dock 轮播 %@ · %lu 个应用 · 每页 %ld",
                               DSCVersion(), (unsigned long)apps.count, (long)perPage]];
}

#pragma mark - 应用列表

// ⚠️ 用户明确要求：没勾选任何应用时，Dock 必须保持系统原本模样。
//    所以这里【不做】任何「自动填全部应用」的兜底 —— 空列表就返回空，
//    上层据此完全卸载覆盖层、恢复系统图标透明度。
- (NSArray<NSString *> *)ds_apps {
    id raw = DSCValue(DSC_KEY_APPS);
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    if ([raw isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)raw) {
            if ([item isKindOfClass:[NSString class]] && [item length] > 0) [list addObject:item];
        }
    }
    return list;
}

#pragma mark - Dock 定位

static NSArray<UIWindow *> *DSAllWindows(void) {
    NSMutableArray<UIWindow *> *out = [NSMutableArray array];
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return out;

    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window && ![out containsObject:window]) [out addObject:window];
        }
    }
    for (UIWindow *window in app.windows) {
        if (window && ![out containsObject:window]) [out addObject:window];
    }
    return out;
}

- (BOOL)ds_frameLooksLikeDock:(CGRect)frame windowSize:(CGSize)windowSize {
    if (frame.size.width < windowSize.width * 0.70) return NO;
    if (frame.size.height < 40.0 || frame.size.height > 220.0) return NO;
    if (CGRectGetMaxY(frame) < windowSize.height * 0.60) return NO;
    return YES;
}

- (UIView *)ds_findDock {
    // ① 缓存命中：Dock 还活着、还在窗口里，就直接用，省掉一次全树遍历
    UIView *cached = _cachedDock;
    if (cached && cached.window && [cached isDescendantOfView:cached.window]) {
        return cached;
    }

    UIView *exact = nil;
    UIView *loose = nil;
    NSMutableArray<NSString *> *seenClasses = [NSMutableArray array];

    for (UIWindow *window in DSAllWindows()) {
        if (window.hidden || window.alpha < 0.01) continue;
        CGSize windowSize = window.bounds.size;

        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:window];
        NSUInteger guard = 0;
        while (queue.count > 0 && guard++ < 6000) {
            UIView *view = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if (!view) continue;

            NSString *className = NSStringFromClass([view class]);
            if (className.length == 0) className = @"?";

            if ([className containsString:@"Dock"]) {
                if (![seenClasses containsObject:className]) [seenClasses addObject:className];
                CGRect frame = [view convertRect:view.bounds toView:window];
                if ([self ds_frameLooksLikeDock:frame windowSize:windowSize]) {
                    BOOL isExact = [className isEqualToString:@"SBDockView"];
                    BOOL isInner = [className containsString:@"IconList"];
                    if (isExact && !exact) {
                        exact = view;
                    } else if (!isInner && !loose) {
                        loose = view;
                    } else if (isInner && !loose && !exact) {
                        loose = view;
                    }
                }
            }
            [queue addObjectsFromArray:view.subviews];
        }
    }

    if (!_loggedDockClasses) {
        _loggedDockClasses = YES;
        if (seenClasses.count) {
            DSLog(@"[Dock] 候选类名：%@", [seenClasses componentsJoinedByString:@", "]);
        } else {
            DSLog(@"[Dock] 没找到任何类名含 Dock 的视图（保持系统 Dock）");
        }
    }

    UIView *result = exact ?: loose;
    _cachedDock = result;
    return result;
}

#pragma mark - 隐藏 / 恢复系统 Dock 图标

- (void)ds_hideSystemIconsIn:(UIView *)dock {
    if (!dock) return;

    // 同一批图标已经藏过且仍存活 → 跳过，避免每秒重复遍历 Dock 子树
    // （还没量到系统图标尺寸时先不跳过，量到了才进入免扫描状态）
    if (_hiddenDock == dock && _hiddenIcons.count > 0 && _systemIconSize > 0.0) {
        for (UIView *view in _hiddenIcons) {
            if (view.window) return;
        }
    }

    NSMutableArray<UIView *> *targets = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:dock];
    NSUInteger guard = 0;

    while (queue.count > 0 && guard++ < 4000) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (!view) continue;

        NSString *className = NSStringFromClass([view class]);
        BOOL isIconList = [className containsString:@"IconList"];
        BOOL isIconView = [className containsString:@"IconView"] && view.bounds.size.width >= 26.0;

        if (isIconList || isIconView) {
            // 顺手量一下系统图标的真实边长 —— 用户要求「图标大小默认跟系统一样」，
            // 与其猜 58 还是 60，不如直接读系统自己的值。
            if (isIconView && _systemIconSize <= 0.0 && view.bounds.size.width > 20.0) {
                _systemIconSize = view.bounds.size.width;
                DSLog(@"[Dock] 系统图标尺寸实测 %.1f pt", _systemIconSize);
            }
            [targets addObject:view];
            continue;   // 命中即止：藏外层就不必再往下钻
        }
        [queue addObjectsFromArray:view.subviews];
    }

    for (UIView *view in targets) {
        if (!objc_getAssociatedObject(view, &kDSOriginalAlphaKey)) {
            objc_setAssociatedObject(view, &kDSOriginalAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (fabs(view.alpha) > 0.001) view.alpha = 0.0;
        if (![_hiddenIcons containsObject:view]) [_hiddenIcons addObject:view];
    }
    _hiddenDock = dock;
}

- (void)ds_restoreSystemIcons {
    for (UIView *view in _hiddenIcons) {
        NSNumber *original = objc_getAssociatedObject(view, &kDSOriginalAlphaKey);
        if (original) {
            view.alpha = (CGFloat)[original doubleValue];
            objc_setAssociatedObject(view, &kDSOriginalAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            view.alpha = 1.0;
        }
    }
    [_hiddenIcons removeAllObjects];
}

#pragma mark - 卸载

- (void)ds_teardown {
    if (_overlay) {
        [_overlay removeFromSuperview];
        _overlay = nil;
        _signature = nil;
    }
    [self ds_restoreSystemIcons];
    _hiddenDock = nil;
    _cachedDock = nil;
}

#pragma mark - 状态横幅

- (void)ds_attachBannerTo:(UIWindow *)window {
    BOOL want = DSCBool(DSC_KEY_BANNER, YES) && !_bannerHiddenByUser;
    if (!want) {
        [_banner removeFromSuperview];
        return;
    }
    if (!_banner) {
        _banner = [UIButton buttonWithType:UIButtonTypeCustom];
        _banner.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
        _banner.layer.cornerRadius = 9.0;
        _banner.clipsToBounds = YES;
        _banner.titleLabel.font = [UIFont monospacedSystemFontOfSize:10.0 weight:UIFontWeightRegular];
        [_banner setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.92] forState:UIControlStateNormal];
        _banner.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        _banner.contentEdgeInsets = UIEdgeInsetsMake(0.0, 8.0, 0.0, 8.0);
        [_banner addTarget:self action:@selector(ds_bannerTapped) forControlEvents:UIControlEventTouchUpInside];
    }
    [_banner sizeToFit];
    CGRect frame = _banner.frame;
    frame.size.width += 16.0;
    frame.size.height = 22.0;
    frame.origin = CGPointMake(10.0, 58.0);
    _banner.frame = frame;

    if (_banner.superview != window) {
        [window addSubview:_banner];
    } else if (window.subviews.lastObject != _banner) {
        [window bringSubviewToFront:_banner];
    }
}

- (void)ds_updateBannerText:(NSString *)text {
    if (!_banner || text.length == 0) return;
    // 每秒 tick 都会调到这里，文案没变就别重设（setTitle 会触发重新布局）
    if ([_bannerText isEqualToString:text]) return;
    _bannerText = [text copy];
    [_banner setTitle:text forState:UIControlStateNormal];
}

- (void)ds_bannerTapped {
    _bannerHiddenByUser = YES;
    [_banner removeFromSuperview];
}

@end
