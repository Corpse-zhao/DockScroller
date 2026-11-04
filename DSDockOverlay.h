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
// iconSize / spacing 传负值表示「跟随系统 / 自动」
- (void)reloadWithApps:(NSArray<NSString *> *)apps
               perPage:(NSInteger)perPage
              iconSize:(CGFloat)iconSize
               spacing:(CGFloat)spacing
         systemIconSize:(CGFloat)systemIconSize;

// 「停在原地」用的位置记忆。
// 用户点开 App 再退回来时，Dock 这一层会被回收重建；如果重建后把 offset
// 归位到第二份开头，就等于每次退出 App 都被踢回第一页。
// ds_logicalOffset ∈ [0, 一份内容的宽度)：表示当前滚到了这一份里的哪个位置。
// 返回负值表示「当前不可滚动 / 没有位置可记」。
- (CGFloat)ds_logicalOffset;

// 重建时恢复到指定位置；传负值表示不恢复（默认）。
@property (nonatomic, assign) CGFloat ds_restoreLogical;

@end
