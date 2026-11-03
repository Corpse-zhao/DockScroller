//
//  DSRootListController.m
//  设置面板根控制器
//
//  设计：完全用 PSListController 自己的 table 与生命周期（这样任何环境下都不会
//  和基类打架），只把 specifier 改成内存里手工构造 —— 不读 plist、不依赖
//  PSBundle 上下文，因此收纳插件里也能正常出条目。
//

#import "DSRootListController.h"
#import "DSAppPickerController.h"
#import "DSPrefsCommon.h"
#import "DSConfig.h"
#import <objc/message.h>

// PSCellType 的常用值（跨版本稳定）
#define DS_CELL_GROUP   0
#define DS_CELL_SWITCH  6
#define DS_CELL_BUTTON  8

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
- (NSArray *)ds_buildSpecifiers;
- (PSSpecifier *)ds_specWithLabel:(NSString *)label cell:(int)cell;
- (PSSpecifier *)ds_groupWithTitle:(NSString *)title footer:(NSString *)footer;
- (PSSpecifier *)ds_buttonWithTitle:(NSString *)title action:(NSString *)action;
- (PSSpecifier *)ds_switchWithTitle:(NSString *)title key:(NSString *)key defaultValue:(BOOL)def;
- (NSString *)ds_perPageTitle;
- (NSString *)ds_iconSizeTitle;
- (NSString *)ds_spacingTitle;
- (id)ds_getSwitch:(PSSpecifier *)spec;
- (void)ds_setSwitch:(id)value specifier:(PSSpecifier *)spec;
- (void)ds_pickNumberForKey:(NSString *)key
                      title:(NSString *)title
                    current:(NSInteger)current
                 candidates:(NSArray<NSNumber *> *)candidates
              labelForValue:(NSString *(^)(NSInteger value))labelForValue;
- (void)openAppPicker;
- (void)fillAll;
- (void)clearAll;
- (void)pickPerPage;
- (void)pickIconSize;
- (void)pickSpacing;
- (void)showLog;
- (void)respring;
- (void)dsReload;
- (void)dsAlert:(NSString *)title message:(NSString *)message;
@end

@implementation DSRootListController

// 这一步能在日志里留下证据：用它区分「bundle 没被加载」和「控制器崩了」
+ (void)load {
    DSPLog(@"[设置] DockScrollerPrefs bundle 已加载 v%@", DSC_VERSION);
}

#pragma mark - specifier 构造

// 用 PS 自己的工厂方法构造，target 直接指向 self
- (PSSpecifier *)ds_specWithLabel:(NSString *)label cell:(int)cell {
    Class cls = NSClassFromString(@"PSSpecifier");
    if (!cls) return nil;

    SEL factory = NSSelectorFromString(@"preferenceSpecifierNamed:target:set:get:detail:cell:edit:");
    if (![cls respondsToSelector:factory]) {
        DSPLog(@"[设置] PSSpecifier 工厂方法不可用");
        return nil;
    }

    id (*fn)(id, SEL, NSString *, id, SEL, SEL, Class, int, Class) =
        (id (*)(id, SEL, NSString *, id, SEL, SEL, Class, int, Class))objc_msgSend;
    PSSpecifier *spec = fn((id)cls, factory, label, self, (SEL)0, (SEL)0, Nil, cell, Nil);
    if (!spec) return nil;

    // ⚠️ 关键：enabled 不显式给 YES，框架会按 NO 处理 —— 整页文字变灰、点不动。
    //    这是「面板出来了但全是暗的」的唯一原因。
    [spec setProperty:@YES forKey:@"enabled"];

    // 再补一份 cell 字符串属性（plist 里的标准写法），和 cellType 双保险：
    // 框架分派 cell 类时两个都可能读，缺一个就可能 fallback 成灰掉的静态样式。
    NSString *cellName = nil;
    if (cell == DS_CELL_GROUP) cellName = @"PSGroupCell";
    else if (cell == DS_CELL_SWITCH) cellName = @"PSSwitchCell";
    else if (cell == DS_CELL_BUTTON) cellName = @"PSButtonCell";
    if (cellName) [spec setProperty:cellName forKey:@"cell"];

    return spec;
}

- (PSSpecifier *)ds_groupWithTitle:(NSString *)title footer:(NSString *)footer {
    PSSpecifier *spec = [self ds_specWithLabel:title cell:DS_CELL_GROUP];
    if (footer.length && [spec respondsToSelector:@selector(setProperty:forKey:)]) {
        [spec setProperty:footer forKey:@"footerText"];
    }
    return spec;
}

- (PSSpecifier *)ds_buttonWithTitle:(NSString *)title action:(NSString *)action {
    PSSpecifier *spec = [self ds_specWithLabel:title cell:DS_CELL_BUTTON];
    if (!spec) return nil;
    [spec setProperty:action forKey:@"action"];
    if ([spec respondsToSelector:@selector(setButtonAction:)]) {
        [spec setButtonAction:NSSelectorFromString(action)];
    }
    if ([spec respondsToSelector:@selector(setTarget:)]) {
        [spec setTarget:self];
    }
    return spec;
}

- (PSSpecifier *)ds_switchWithTitle:(NSString *)title key:(NSString *)key defaultValue:(BOOL)def {
    PSSpecifier *spec = [self ds_specWithLabel:title cell:DS_CELL_SWITCH];
    if (!spec) return nil;

    // 三件套齐全，PSSwitchCell 才知道读哪个域、哪个键、默认值是什么
    [spec setProperty:key forKey:@"key"];
    [spec setProperty:DSC_DOMAIN forKey:@"defaults"];
    [spec setProperty:[NSNumber numberWithBool:def] forKey:@"default"];

    // 首次渲染时 PSSwitchCell 可能先读 value 属性再问 getter，
    // 这里先塞一个当前真实值，避免第一帧显示成关、随后又被弹回
    [spec setProperty:[NSNumber numberWithBool:DSPBool(key, def)] forKey:@"value"];

    // 再挂上自己的读写方法，双保险（不同 iOS 版本方法名不一样）
    if ([spec respondsToSelector:@selector(setCellTarget:)]) {
        [spec setCellTarget:self];
    }
    if ([spec respondsToSelector:@selector(setCellSetter:)]) {
        [spec setCellSetter:@selector(ds_setSwitch:specifier:)];
    }
    if ([spec respondsToSelector:@selector(setCellGetter:)]) {
        [spec setCellGetter:@selector(ds_getSwitch:)];
    }
    if ([spec respondsToSelector:NSSelectorFromString(@"setSetter:")]) {
        ((void (*)(id, SEL, SEL))objc_msgSend)(spec, NSSelectorFromString(@"setSetter:"),
                                              @selector(ds_setSwitch:specifier:));
    }
    if ([spec respondsToSelector:NSSelectorFromString(@"setGetter:")]) {
        ((void (*)(id, SEL, SEL))objc_msgSend)(spec, NSSelectorFromString(@"setGetter:"),
                                              @selector(ds_getSwitch:));
    }
    return spec;
}

- (NSArray *)ds_buildSpecifiers {
    NSMutableArray *out = [NSMutableArray array];

    void (^add)(PSSpecifier *) = ^(PSSpecifier *spec) {
        if (spec) [out addObject:spec];
    };

    add([self ds_groupWithTitle:@"总开关"
                         footer:@"关闭后立即恢复系统原生 Dock（固定 4 个图标）。"]);
    add([self ds_switchWithTitle:@"启用左右滑动 Dock" key:DSC_KEY_ENABLED defaultValue:YES]);

    add([self ds_groupWithTitle:@"Dock 应用"
                         footer:@"不勾选任何应用时，Dock 保持系统原本模样，插件不做任何改动。"]);
    add([self ds_buttonWithTitle:@"选择放进 Dock 的应用" action:@"openAppPicker"]);
    add([self ds_buttonWithTitle:@"一键填入全部应用" action:@"fillAll"]);
    add([self ds_buttonWithTitle:@"清空列表" action:@"clearAll"]);

    add([self ds_groupWithTitle:@"外观"
                         footer:@"图标大小默认取系统 Dock 的实测值；间距选「自动」时图标在槽位内居中。"]);
    add([self ds_buttonWithTitle:[self ds_perPageTitle] action:@"pickPerPage"]);
    add([self ds_buttonWithTitle:[self ds_iconSizeTitle] action:@"pickIconSize"]);
    add([self ds_buttonWithTitle:[self ds_spacingTitle] action:@"pickSpacing"]);

    add([self ds_groupWithTitle:@"诊断"
                         footer:[NSString stringWithFormat:
                                 @"版本 %@ · 改完设置回到桌面约 1 秒内生效，无需重启桌面。", DSC_VERSION]]);
    add([self ds_switchWithTitle:@"显示状态小横条" key:DSC_KEY_BANNER defaultValue:YES]);
    add([self ds_buttonWithTitle:@"查看诊断日志" action:@"showLog"]);
    add([self ds_buttonWithTitle:@"重启桌面" action:@"respring"]);

    return out;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self ds_buildSpecifiers];
        DSPLog(@"[设置] 构造 specifier 完成，共 %lu 项", (unsigned long)_specifiers.count);
    }
    return _specifiers;
}

#pragma mark - 标题（带当前值）

- (NSString *)ds_perPageTitle {
    return [NSString stringWithFormat:@"每页图标数：%ld 个",
            (long)DSPInt(DSC_KEY_PER_PAGE, DSC_DEFAULT_PER_PAGE)];
}

- (NSString *)ds_iconSizeTitle {
    NSInteger v = DSPInt(DSC_KEY_ICON_SIZE, DSC_SIZE_AUTO);
    return (v > 0) ? [NSString stringWithFormat:@"图标大小：%ld pt", (long)v]
                   : @"图标大小：跟随系统";
}

- (NSString *)ds_spacingTitle {
    NSInteger v = DSPInt(DSC_KEY_SPACING, DSC_SIZE_AUTO);
    return (v >= 0) ? [NSString stringWithFormat:@"图标间距：%ld pt", (long)v]
                    : @"图标间距：自动";
}

#pragma mark - 开关读写

// key 属性万一丢了，就按标题反推（标题是固定的，两个开关能可靠区分）
- (NSString *)ds_keyForSpec:(PSSpecifier *)spec {
    id key = [spec propertyForKey:@"key"];
    if ([key isKindOfClass:[NSString class]] && [(NSString *)key length] > 0) return key;

    NSString *name = nil;
    if ([spec respondsToSelector:@selector(name)]) name = [spec name];
    if ([name containsString:@"横条"]) return DSC_KEY_BANNER;
    if ([name containsString:@"滑动"]) return DSC_KEY_ENABLED;
    DSPLog(@"[设置] 警告：specifier 取不到 key（name=%@）", name);
    return DSC_KEY_ENABLED;
}

// 框架渲染开关时会问这两个方法要值 / 存值。
// 覆盖掉，读写就直接落到我们自己的配置（config.plist 优先，见 DSPrefsCommon 注释）。
- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [self ds_keyForSpec:spec];
    NSNumber *value = [NSNumber numberWithBool:DSPBool(key, YES)];

    // 有些版本的 PSSwitchCell 会缓存 specifier 的 value 属性，
    // 不同步一份的话拨动后会被旧值弹回去
    [spec setProperty:value forKey:@"value"];
    DSPLog(@"[设置] 读 %@ = %@", key, value.boolValue ? @"开" : @"关");
    return value;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [self ds_keyForSpec:spec];
    BOOL on = [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;

    DSPSetBool(key, on);
    [spec setProperty:[NSNumber numberWithBool:on] forKey:@"value"];
    DSPLog(@"[设置] 写 %@ = %@", key, on ? @"开" : @"关");
}

- (id)ds_getSwitch:(PSSpecifier *)spec {
    return [self readPreferenceValue:spec];
}

- (void)ds_setSwitch:(id)value specifier:(PSSpecifier *)spec {
    [self setPreferenceValue:value specifier:spec];
}

#pragma mark - 动作

- (void)openAppPicker {
    DSPLog(@"[设置] 打开应用选择页");
    DSAppPickerController *picker =
        [[DSAppPickerController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav = self.navigationController;
    if (nav) {
        [nav pushViewController:picker animated:YES];
    } else {
        UINavigationController *wrapper =
            [[UINavigationController alloc] initWithRootViewController:picker];
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
    [self dsAlert:@"已填入全部应用"
          message:[NSString stringWithFormat:@"共 %lu 个，回到桌面左右滑动 Dock 即可看到。",
                   (unsigned long)ids.count]];
}

- (void)clearAll {
    DSPAppsSet(@[]);
    [self dsReload];
    [self dsAlert:@"已清空"
          message:@"清空后 Dock 会恢复系统原生模样（不再有轮播）。想再启用，请到「选择放进 Dock 的应用」里勾选。"];
}

- (void)ds_pickNumberForKey:(NSString *)key
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
        NSInteger captured = value;
        [sheet addAction:[UIAlertAction actionWithTitle:text
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *act) {
            DSPSetInt(key, captured);
            [self dsReload];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    // iPad 上不设 sourceView 会直接崩
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1.0, 1.0);
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pickPerPage {
    NSInteger current = DSPInt(DSC_KEY_PER_PAGE, DSC_DEFAULT_PER_PAGE);
    [self ds_pickNumberForKey:DSC_KEY_PER_PAGE
                        title:[NSString stringWithFormat:@"每页显示几个图标（当前 %ld，最多 5 个）", (long)current]
                      current:current
                   candidates:@[ @1, @2, @3, @4, @5 ]
                 labelForValue:^NSString *(NSInteger value) {
        return [NSString stringWithFormat:@"%ld 个", (long)value];
    }];
}

- (void)pickIconSize {
    NSInteger current = DSPInt(DSC_KEY_ICON_SIZE, DSC_SIZE_AUTO);
    [self ds_pickNumberForKey:DSC_KEY_ICON_SIZE
                        title:[NSString stringWithFormat:@"图标大小（当前 %@）",
                               current > 0 ? [NSString stringWithFormat:@"%ld pt", (long)current] : @"跟随系统"]
                      current:current
                   candidates:@[ @(DSC_SIZE_AUTO), @40, @44, @48, @52, @56, @60, @64, @68, @72 ]
                 labelForValue:^NSString *(NSInteger value) {
        if (value < 0) return @"跟随系统（推荐）";
        return [NSString stringWithFormat:@"%ld pt", (long)value];
    }];
}

- (void)pickSpacing {
    NSInteger current = DSPInt(DSC_KEY_SPACING, DSC_SIZE_AUTO);
    [self ds_pickNumberForKey:DSC_KEY_SPACING
                        title:[NSString stringWithFormat:@"图标间距（当前 %@）",
                               current >= 0 ? [NSString stringWithFormat:@"%ld pt", (long)current] : @"自动"]
                      current:current
                   candidates:@[ @(DSC_SIZE_AUTO), @0, @2, @4, @6, @8, @10, @14, @18 ]
                 labelForValue:^NSString *(NSInteger value) {
        if (value < 0) return @"自动（推荐）";
        return [NSString stringWithFormat:@"%ld pt", (long)value];
    }];
}

- (void)showLog {
    NSString *path = DSPLogPath();
    NSString *content = nil;
    if (path.length) {
        content = [NSString stringWithContentsOfFile:path
                                            encoding:NSUTF8StringEncoding
                                               error:NULL];
    }
    if (content.length == 0) {
        content = @"（暂时没有日志）\n\n插件写入日志的位置：\n/var/mobile/Documents/DockScroller/dock.log\n\n如果插件压根没跑起来，这个文件就不会出现。";
    }
    DSPLogViewController *viewer = [[DSPLogViewController alloc] init];
    viewer.content = content;

    UINavigationController *nav = self.navigationController;
    if (nav) {
        [nav pushViewController:viewer animated:YES];
    } else {
        UINavigationController *wrapper =
            [[UINavigationController alloc] initWithRootViewController:viewer];
        [self presentViewController:wrapper animated:YES completion:nil];
    }
}

- (void)respring {
    DSPLog(@"[设置] 用户点了重启桌面");
    DSPRespring();
}

#pragma mark - 辅助

// 重建 specifier 数组（标题里带当前值）+ 刷新表格
- (void)dsReload {
    _specifiers = [self ds_buildSpecifiers];
    [self reloadSpecifiers];
}

- (void)dsAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title
                                            message:message ?: @""
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
