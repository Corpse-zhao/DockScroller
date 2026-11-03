//
//  DSRootListController.h
//  设置面板根控制器
//
//  ⚠️ 三条真机血泪经验（v0.1.1 可用 / v0.1.2 全崩 / v0.1.3 全崩 换来的）：
//
//  1) 必须继承真实的 PSListController —— 收纳插件（OneSettings）会无保护地调
//     `setSpecifier:` 等 PS 方法，纯 UIViewController 会被 unrecognized selector 打崩。
//
//  2) 绝不能重写 loadView / 拿走基类的 view —— PSListController 内部大量假设
//     self.view 就是它自己的 UITableView，一旦换成普通 UIView，基类随便哪个回调
//     都会把 UIView 当 table 用 → 崩。v0.1.3 两种入口全崩就是这个原因。
//
//  3) 但也不能依赖 loadSpecifiersFromPlistName: 去读 plist —— 收纳插件不装配
//     PSBundle 上下文，找不到 plist，页面空白且不报错（v0.1.1 的表现）。
//
//  解法：用基类的 table 与生命周期，specifier 全部【内存里手工构造】。
//        这样既不需要 bundle 上下文，也不碰基类的 view。
//

#import <UIKit/UIKit.h>

@interface PSSpecifier : NSObject
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
- (void)setTarget:(id)target;
- (void)setButtonAction:(SEL)action;
- (void)setCellTarget:(id)target;
- (void)setCellSetter:(SEL)setter;
- (void)setCellGetter:(SEL)getter;
- (void)setName:(NSString *)name;
- (NSString *)name;
@end

@interface PSListController : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    @protected
    // ⚠️ 必须声明在基类接口里：表格数据源直接访问基类自己那个 ivar，
    //    放别处基类永远看到 nil，表现是「能进面板但整页空白」。
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (UITableView *)table;
- (void)setSpecifier:(id)specifier;
- (id)specifier;
@end

@interface DSRootListController : PSListController
@end
