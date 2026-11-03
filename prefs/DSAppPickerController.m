//
//  DSAppPickerController.m
//  原生 UITableViewController —— 完全不碰 PSSpecifier，避免私有构造导致的闪退
//

#import "DSAppPickerController.h"
#import "DSPrefsCommon.h"
#import "DSConfig.h"

@interface DSAppPickerController ()
@property (nonatomic, strong) NSArray<NSDictionary *> *allApps;
@property (nonatomic, strong) NSMutableArray<NSString *> *selected;
@end

@implementation DSAppPickerController

- (instancetype)initWithStyle:(UITableViewStyle)style {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _selected = [NSMutableArray arrayWithArray:DSPApps()];
        _allApps = DSPInstalledUserApps();
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"选择 Dock 应用";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                     target:self
                                                     action:@selector(dsSave)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                     target:self
                                                     action:@selector(dsCancel)];

    if (self.allApps.count == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectZero];
        empty.text = @"没有枚举到已安装的应用。\n请确认设备是越狱环境后重开设置。";
        empty.numberOfLines = 0;
        empty.textAlignment = NSTextAlignmentCenter;
        empty.textColor = [UIColor secondaryLabelColor];
        empty.font = [UIFont systemFontOfSize:14.0];
        self.tableView.backgroundView = empty;
    }
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.allApps.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"已选 %lu 个 · 点按切换 · 顺序即 Dock 排列顺序",
            (unsigned long)self.selected.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"一个都不选时，Dock 会自动使用全部已安装应用。左右滑动可无限循环翻看。";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"DSAppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    }

    NSDictionary *app = self.allApps[(NSUInteger)indexPath.row];
    NSString *bid = app[@"id"];
    cell.textLabel.text = app[@"name"];
    cell.imageView.image = DSPIconForBundle(bid, 30.0);

    NSUInteger order = [self.selected indexOfObject:bid];
    if (order != NSNotFound) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"第 %lu 个", (unsigned long)(order + 1)];
        cell.detailTextLabel.textColor = [UIColor systemBlueColor];
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    } else {
        cell.detailTextLabel.text = bid;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSDictionary *app = self.allApps[(NSUInteger)indexPath.row];
    NSString *bid = app[@"id"];
    if (bid.length == 0) return;

    NSUInteger order = [self.selected indexOfObject:bid];
    if (order == NSNotFound) {
        [self.selected addObject:bid];
    } else {
        [self.selected removeObjectAtIndex:order];
    }
    [tableView reloadData];
}

#pragma mark - 保存 / 取消

- (void)dsSave {
    DSPAppsSet(self.selected);
    [self dsLeave];
}

- (void)dsCancel {
    [self dsLeave];
}

- (void)dsLeave {
    if (self.navigationController.viewControllers.firstObject == self) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

@end
