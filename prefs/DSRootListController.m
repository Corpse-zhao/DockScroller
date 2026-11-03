//
//  DSRootListController.m
//  设置面板根控制器（完全自绘版）
//
//  为什么自绘：PSListController / PSSpecifier 依赖原生「设置」代为装配的
//  bundle 上下文；OneSettings 等收纳插件自己实例化 detail，不给这套上下文，
//  结果就是整页空白。自绘 UITableView + UISwitch 不依赖任何私有机制，
//  原生设置、OneSettings、任何收纳插件都能正常 push 与渲染。
//
//  开关直接读写 NSUserDefaults（DSPrefsCommon 同时落盘 config.plist 并发
//  Darwin 通知），插件端 1 秒轮询内生效。
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

static const void *kDSActionKey = "ds_action";
static const void *kDSKeyKey = "ds_key";

@interface DSRootListController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
- (NSString *)ds_perPageText;
- (NSString *)ds_iconSizeText;
- (NSString *)ds_spacingText;
- (UISwitch *)ds_switchForKey:(NSString *)key default:(BOOL)def;
- (void)ds_switchChanged:(UISwitch *)sender;
- (void)ds_pickNumberForKey:(NSString *)key
                      title:(NSString *)title
                    current:(NSInteger)current
                 candidates:(NSArray<NSNumber *> *)candidates
              labelForValue:(NSString *(^)(NSInteger value))labelForValue;
@end

@implementation DSRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Dock 轮播";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    _table = [[UITableView alloc] initWithFrame:self.view.bounds
                                          style:UITableViewStyleInsetGrouped];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    _table.backgroundColor = [UIColor systemBackgroundColor];
    [self.view addSubview:_table];
    DSPLog(@"[设置] 自绘面板已加载");
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [_table reloadData];   // 从子页面（应用选择）回来时刷新当前值显示
}

#pragma mark - 表格结构

//  0 总开关 | 1 Dock 应用 | 2 外观 | 3 诊断
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1;   // 总开关只有一行
        default: return 3;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"总开关";
        case 1: return @"Dock 应用";
        case 2: return @"外观";
        case 3: return @"诊断";
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case 0:
            return @"关闭后立即恢复系统原生 Dock（固定 4 个图标）。";
        case 1:
            return @"不勾选任何应用时，Dock 保持系统原本模样，插件不做任何改动。";
        case 2:
            return @"图标大小默认取系统 Dock 的实测值，与原生完全一致；间距选「自动」时图标在槽位内居中。";
        case 3:
            return [NSString stringWithFormat:@"版本 %@ · 改完设置回到桌面约 1 秒内生效，无需重启桌面。",
                    DSC_VERSION];
    }
    return nil;
}

#pragma mark - 行内容

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"DSCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:reuse];
    }
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    objc_setAssociatedObject(cell, kDSActionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSInteger section = indexPath.section;
    NSInteger row = indexPath.row;

    if (section == 0 && row == 0) {
        cell.textLabel.text = @"启用左右滑动 Dock";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryView = [self ds_switchForKey:DSC_KEY_ENABLED default:YES];
    } else if (section == 1) {
        NSArray<NSString *> *titles = @[ @"选择放进 Dock 的应用", @"一键填入全部应用", @"清空列表" ];
        NSArray<NSString *> *actions = @[ @"openAppPicker", @"fillAll", @"clearAll" ];
        cell.textLabel.text = titles[row];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        objc_setAssociatedObject(cell, kDSActionKey, actions[row], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (section == 2) {
        NSArray<NSString *> *titles = @[ @"每页图标数", @"图标大小", @"图标间距" ];
        NSArray<NSString *> *actions = @[ @"pickPerPage", @"pickIconSize", @"pickSpacing" ];
        NSArray<NSString *> *values = @[ [self ds_perPageText], [self ds_iconSizeText], [self ds_spacingText] ];
        cell.textLabel.text = titles[row];
        cell.detailTextLabel.text = values[row];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        objc_setAssociatedObject(cell, kDSActionKey, actions[row], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (section == 3) {
        if (row == 0) {
            cell.textLabel.text = @"显示状态小横条";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryView = [self ds_switchForKey:DSC_KEY_BANNER default:YES];
        } else {
            cell.textLabel.text = (row == 1) ? @"查看诊断日志" : @"重启桌面";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            objc_setAssociatedObject(cell, kDSActionKey,
                                     (row == 1) ? @"showLog" : @"respring",
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return cell;
}

#pragma mark - 交互

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    // 开关行由 UISwitch 自己处理，点击行体不做动作
    if (indexPath.section == 0 || (indexPath.section == 3 && indexPath.row == 0)) return;

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    NSString *action = objc_getAssociatedObject(cell, kDSActionKey);
    if (action.length == 0) return;

    SEL sel = NSSelectorFromString(action);
    if ([self respondsToSelector:sel]) {
        ((void (*)(id, SEL))objc_msgSend)(self, sel);
    } else {
        DSPLog(@"[设置] action %@ 找不到实现", action);
    }
}

- (void)ds_switchChanged:(UISwitch *)sender {
    NSString *key = objc_getAssociatedObject(sender, kDSKeyKey);
    if (key.length == 0) return;
    DSPSetBool(key, sender.on);
}

#pragma mark - 当前值文案

- (NSString *)ds_perPageText {
    return [NSString stringWithFormat:@"%ld 个",
            (long)DSPInt(DSC_KEY_PER_PAGE, DSC_DEFAULT_PER_PAGE)];
}

- (NSString *)ds_iconSizeText {
    NSInteger v = DSPInt(DSC_KEY_ICON_SIZE, DSC_SIZE_AUTO);
    return (v > 0) ? [NSString stringWithFormat:@"%ld pt", (long)v] : @"跟随系统";
}

- (NSString *)ds_spacingText {
    NSInteger v = DSPInt(DSC_KEY_SPACING, DSC_SIZE_AUTO);
    return (v >= 0) ? [NSString stringWithFormat:@"%ld pt", (long)v] : @"自动";
}

#pragma mark - 控件工厂

- (UISwitch *)ds_switchForKey:(NSString *)key default:(BOOL)def {
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = DSPBool(key, def);
    objc_setAssociatedObject(sw, kDSKeyKey, key, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sw addTarget:self action:@selector(ds_switchChanged:) forControlEvents:UIControlEventValueChanged];
    return sw;
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
                        title:[NSString stringWithFormat:@"图标大小（当前 %@）", [self ds_iconSizeText]]
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
                        title:[NSString stringWithFormat:@"图标间距（当前 %@）", [self ds_spacingText]]
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

- (void)dsReload {
    [_table reloadData];
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
