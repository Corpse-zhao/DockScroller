//
//  DSRootListController.h
//  设置面板根控制器
//
//  ⚠️ 两个必须同时满足的条件（都是真机踩出来的）：
//
//  1) 必须【继承真实的 PSListController】。
//     OneSettings 这类收纳插件在实例化 detail 之后会无保护地调用
//     `setSpecifier:` 等 PS 私有方法；纯 UIViewController 上没有这些方法，
//     结果是「点一下设置直接闪退」。原生「设置」也按 PS 控制器的方式对待
//     detail，给普通 VC 会变成整页空白 —— 所以类身份必须是 PS 的。
//
//  2) 但【不能用 specifier 机制】。
//     收纳插件不会像原生 Preferences 那样装配 PSBundle 上下文，
//     loadSpecifiersFromPlistName: 找不到 plist → 整页空白且不报错。
//     所以界面全部自绘（UITableView + UISwitch），只借用 PS 的类壳子。
//
//  PSListController 是私有类，SDK 里没有声明，这里只补编译期需要的部分；
//  运行期解析到的是 Preferences.framework 里的真实类。
//

#import <UIKit/UIKit.h>

@interface PSListController : UIViewController
- (void)setSpecifier:(id)specifier;
- (id)specifier;
- (NSArray *)specifiers;
- (void)reloadSpecifiers;
- (void)reload;
@end

@interface DSRootListController : PSListController
@end
