//
//  DSRootListController.m
//  设置面板根控制器
//
//  plist 里所有 action 都是【无参 PSButtonCell】，这是在本机实测点得动的形态。
//  需要页面跳转的一律自己 alloc + push（不用 plist 的 detail 键，那个会让框架
//  自己去实例化控制器，给纯 UIKit 控制器会直接闪退）。
//

#import "DSRootListController.h"
#import "DSAppPickerController.h"
#import "DSPrefsCommon.h"
#import "DSConfig.h"
#import <objc/message.h>

#pragma mark - 日志查看器

@interface DSPLogViewController : UIViewController
@property (nonatomic, copy) NSString *content;
@end

@implementation DSPLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"诊断日志";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UITextView *textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.alwaysBounceVertical = YES;
    textView.font = [UIFont monospacedSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    textView.text = self.content.length ? self.content : @"（日志为空）";
    [self.view addSubview:textView];
}

@end

#pragma mark - 根控制器

@interface DSRootListController ()
- (NSArray *)ds_fallbackSpecifiers;
- (void)ds_pickNumberForAction:(NSString *)action
                         title:(NSString *)title
                       current:(NSInteger)current
                    candidates:(NSArray<NSNumber *> *)candidates
                 labelForValue:(NSString *(^)(NSInteger value))labelForValue;
- (NSString *)ds_keyForAction:(NSString *)action;
- (void)ds_refreshTitles;
- (void)dsReload;
- (void)dsAlert:(NSString *)title message:(NSString *)message;
@end

@implementation DSRootListController

// 兜底：框架若因 bundle 上下文找不到 Root.plist，就自己定位并手工构造
- (NSArray *)ds_fallbackSpecifiers {
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSURL *url = [bundle URLForResource:@"Root" withExtension:@"plist"];
    if (!url) {
        DSPLog(@"[设置] 兜底也找不到 Root.plist（bundle=%@）", bundle.bundlePath);
        return @[];
    }
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfURL:url];
    NSArray *items = root[@"items"];
    if (![items isKindOfClass:[NSArray class]]) return @[];

    Class specClass = NSClassFromString(@"PSSpecifier");
    SEL factory = NSSelectorFromString(@"specifierWithProperties:");
    NSMutableArray *built = [NSMutableArray array];
    for (id item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        id spec = nil;
        if ([specClass respondsToSelector:factory]) {
            spec = ((id (*)(id, SEL, id))objc_msgSend)(specClass, factory, item);
        }
        if (spec) [built addObject:spec];
    }
    DSPLog(@"[设置] 兜底构造 %lu 项（Root.plist=%@）", (unsigned long)built.count, url.lastPathComponent);
    return built;
}

// ⚠️ 必须自己 override：PSListController 的 specifiers 只是返回 _specifiers，
//    没人填它就是 nil → 能进面板但整页空白（且不报错）。
- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        if (_specifiers.count == 0) {
            _specifiers = [self ds_fallbackSpecifiers];
        }
        DSPLog(@"[设置] Root.plist 载入 %lu 项", (unsigned long)_specifiers.count);
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 先确保 specifiers 已加载，再刷新（只 reloadData 会在首次进来时刷不到东西）
    (void)[self specifiers];
    [self ds_refreshTitles];   // 按钮标题里带上当前值
    [self reloadSpecifiers];
}

#pragma mark - 动作

- (void)openAppPicker {
    DSPLog(@"[设置] 打开应用选择页");
    DSAppPickerController *picker = [[DSAppPickerController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav = [self navigationController];
    if (nav) {
        [nav pushViewController:picker animated:YES];
    } else {
        UINavigationController *wrapper = [[UINavigationController alloc] initWithRootViewController:picker];
        [self presentViewController:wrapper animated:YES completion:nil];
    }
}

- (void)fillAll {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (NSDictionary *app in DSPInstalledUserApps()) {
        NSString *bid = app[@"id"];
        if ([bid isKindOfClass:[NSString class]] && bid.length) [ids addObject:bid];
    }
    if (ids.count == 0) {
        [self dsAlert:@"没有可选应用" message:@"没有枚举到已安装的应用，请确认越狱环境正常。"];
        return;
    }
    DSPAppsSet(ids);
    [self dsReload];
    [self dsAlert:@"已填入全部应用" message:[NSString stringWithFormat:@"共 %lu 个，回到桌面左右滑动 Dock 即可看到。", (unsigned long)ids.count]];
}

- (void)clearAll {
    DSPAppsSet(@[]);
    [self dsReload];
    [self dsAlert:@"已清空" message:@"清空后 Dock 会恢复系统原生模样（不再有轮播）。想再启用，请到「选择放进 Dock 的应用」里勾选。"];
}

// 通用：弹一个数字选择表。candidates 里用 -1 表示「自动 / 跟随系统」
- (void)ds_pickNumberForAction:(NSString *)action
                         title:(NSString *)title
                       current:(NSInteger)current
                    candidates:(NSArray<NSNumber *> *)candidates
                    labelForValue:(NSString *(^)(NSInteger value))labelForValue {
    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:title
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSNumber *number in candidates) {
        NSInteger value = [number integerValue];
        NSString *text = labelForValue(value);
        if (value == current) text = [text stringByAppendingString:@" ✓"];
        [sheet addAction:[UIAlertAction actionWithTitle:text
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *act) {
            DSPSetInt([self ds_keyForAction:action], value);
            [self dsReload];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                               CGRectGetMidY(self.view.bounds), 1.0, 1.0);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (NSString *)ds_keyForAction:(NSString *)action {
    if ([action isEqualToString:@"pickPerPage"]) return DSC_KEY_PER_PAGE;
    if ([action isEqualToString:@"pickIconSize"]) return DSC_KEY_ICON_SIZE;
    if ([action isEqualToString:@"pickSpacing"]) return DSC_KEY_SPACING;
    return action;
}

- (void)pickPerPage {
    NSInteger current = DSPInt(DSC_KEY_PER_PAGE, DSC_DEFAULT_PER_PAGE);
    NSString *title = [NSString stringWithFormat:@"每页显示几个图标（当前 %ld，最多 5 个）", (long)current];
    [self ds_pickNumberForAction:@"pickPerPage"
                           title:title
                         current:current
                      candidates:@[ @1, @2, @3, @4, @5 ]
                    labelForValue:^NSString *(NSInteger value) {
        return [NSString stringWithFormat:@"%ld 个", (long)value];
    }];
    [self ds_refreshTitles];
}

- (void)pickIconSize {
    NSInteger current = DSPInt(DSC_KEY_ICON_SIZE, DSC_SIZE_AUTO);
    NSString *title = [NSString stringWithFormat:@"图标大小（当前 %@）",
                       current > 0 ? [NSString stringWithFormat:@"%ld pt", (long)current] : @"跟随系统"];
    [self ds_pickNumberForAction:@"pickIconSize"
                           title:title
                         current:current
                      candidates:@[ @(DSC_SIZE_AUTO), @40, @44, @48, @52, @56, @60, @64, @68, @72 ]
                    labelForValue:^NSString *(NSInteger value) {
        if (value < 0) return @"跟随系统（推荐）";
        return [NSString stringWithFormat:@"%ld pt", (long)value];
    }];
    [self ds_refreshTitles];
}

- (void)pickSpacing {
    NSInteger current = DSPInt(DSC_KEY_SPACING, DSC_SIZE_AUTO);
    NSString *title = [NSString stringWithFormat:@"图标间距（当前 %@）",
                       current >= 0 ? [NSString stringWithFormat:@"%ld pt", (long)current] : @"自动"];
    [self ds_pickNumberForAction:@"pickSpacing"
                           title:title
                         current:current
                      candidates:@[ @(DSC_SIZE_AUTO), @0, @2, @4, @6, @8, @10, @14, @18 ]
                    labelForValue:^NSString *(NSInteger value) {
        if (value < 0) return @"自动（推荐）";
        return [NSString stringWithFormat:@"%ld pt", (long)value];
    }];
    [self ds_refreshTitles];
}

// 把当前值直接写进按钮标题，省得用户点进去才知道现在是多少
- (void)ds_refreshTitles {
    NSInteger perPage = DSPInt(DSC_KEY_PER_PAGE, DSC_DEFAULT_PER_PAGE);
    NSInteger iconSize = DSPInt(DSC_KEY_ICON_SIZE, DSC_SIZE_AUTO);
    NSInteger spacing = DSPInt(DSC_KEY_SPACING, DSC_SIZE_AUTO);

    NSArray *texts = @[
        [NSString stringWithFormat:@"每页图标数：%ld 个", (long)perPage],
        [NSString stringWithFormat:@"图标大小：%@",
         iconSize > 0 ? [NSString stringWithFormat:@"%ld pt", (long)iconSize] : @"跟随系统"],
        [NSString stringWithFormat:@"图标间距：%@",
         spacing >= 0 ? [NSString stringWithFormat:@"%ld pt", (long)spacing] : @"自动"],
    ];
    NSArray *actions = @[ @"pickPerPage", @"pickIconSize", @"pickSpacing" ];

    for (NSUInteger i = 0; i < actions.count; i++) {
        for (PSSpecifier *spec in _specifiers) {
            NSString *action = [spec propertyForKey:@"action"];
            if (![action isEqualToString:actions[i]]) continue;
            [spec setProperty:texts[i] forKey:@"label"];
            break;
        }
    }
}

- (void)showLog {
    NSString *path = DSPLogPath();
    NSString *content = nil;
    if (path.length) content = [NSString stringWithContentsOfFile:path
                                                        encoding:NSUTF8StringEncoding
                                                           error:NULL];
    if (content.length == 0) {
        content = @"（暂时没有日志）\n\n插件写入日志的位置：\n/var/mobile/Documents/DockScroller/dock.log\n\n如果插件压根没跑起来，这个文件就不会出现。";
    }
    DSPLogViewController *viewer = [[DSPLogViewController alloc] init];
    viewer.content = content;

    UINavigationController *nav = [self navigationController];
    if (nav) {
        [nav pushViewController:viewer animated:YES];
    } else {
        UINavigationController *wrapper = [[UINavigationController alloc] initWithRootViewController:viewer];
        [self presentViewController:wrapper animated:YES completion:nil];
    }
}

- (void)respring {
    DSPLog(@"[设置] 用户点了重启桌面");
    DSPRespring();
}

#pragma mark - 辅助

- (void)dsAlert:(NSString *)title message:(NSString *)message {
    NSString *body = message ?: @"";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:body
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)dsReload {
    // 改了 specifier 的 label（标题里带当前值）后，必须走 reloadSpecifiers 才会重建 cell
    [self reloadSpecifiers];
}

@end
