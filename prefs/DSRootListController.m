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

@implementation DSRootListController

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UITableView *table = [self table];
    if (table) [table reloadData];
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
    [self dsAlert:@"已清空" message:@"清空后 Dock 会自动使用全部已安装应用。若想恢复系统原生 Dock，请把上面的开关关掉。"];
}

- (void)pickPerPage {
    NSInteger current = DSPInt(DSC_KEY_PER_PAGE, DSC_DEFAULT_PER_PAGE);
    NSString *title = [NSString stringWithFormat:@"每页显示几个图标（当前 %ld）", (long)current];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *number in @[ @3, @4, @5, @6 ]) {
        NSInteger value = [number integerValue];
        NSString *label = [NSString stringWithFormat:@"%ld 个%@", (long)value, (value == current ? @" ✓" : @"")];
        [sheet addAction:[UIAlertAction actionWithTitle:label
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            DSPSetInt(DSC_KEY_PER_PAGE, value);
            [self dsReload];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 上不设 sourceView 会直接崩
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                               CGRectGetMidY(self.view.bounds), 1.0, 1.0);
    [self presentViewController:sheet animated:YES completion:nil];
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
    UITableView *table = [self table];
    if (table) [table reloadData];
}

@end
