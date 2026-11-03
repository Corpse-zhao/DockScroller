//
//  DSRootListController.h
//  设置面板根控制器
//
//  ⚠️ PSListController 是私有类（Preferences.framework），SDK 里没有声明，
//     必须自己声明；而且 _specifiers 这个 ivar 必须声明在【基类接口】里 ——
//     表格数据源是直接访问基类自己那个 ivar 的，子类放别处基类永远看到 nil，
//     表现是「能进面板但整页空白」，且不报任何错。
//

#import <UIKit/UIKit.h>

@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;
@end

@interface PSListController : UIViewController <UITableViewDataSource, UITableViewDelegate> {
    @protected
    NSArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (UITableView *)table;
@end

@interface DSRootListController : PSListController
@end
