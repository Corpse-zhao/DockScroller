//
//  DSDockOverlay.h
//  DockScroller —— 自绘的「闭环轮播 Dock」
//
//  实现要点：
//  · 把所选应用横向重复若干份铺进 content，首尾完全一致；
//  · 滚到接缝时用 contentOffset 整体平移一份宽度，视觉上无缝；
//  · 松手吸附到最近的图标槽位，可以从左往右、也可以从右往左无限滑。
//

#import <UIKit/UIKit.h>

@interface DSDockOverlayView : UIView <UIScrollViewDelegate>

@property (nonatomic, strong, readonly) UIScrollView *scrollView;

// 重新安装应用列表（同一签名重复调用会被上层拦住，不会反复重建）
- (void)reloadWithApps:(NSArray<NSString *> *)apps perPage:(NSInteger)perPage;

@end
