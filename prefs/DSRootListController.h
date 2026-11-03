//
//  DSRootListController.h
//  设置面板根控制器（完全自绘版）
//
//  ⚠️ 为什么不继承 PSListController：
//     OneSettings 这类收纳插件实例化 detail 时不会像原生 Preferences 那样
//     配好 PSBundle 上下文，loadSpecifiersFromPlistName: 会找不到 plist →
//     整页空白且不报错。纯 UIKit 自绘不依赖任何私有机制，任何环境下都能显示。
//

#import <UIKit/UIKit.h>

@interface DSRootListController : UIViewController
@end
