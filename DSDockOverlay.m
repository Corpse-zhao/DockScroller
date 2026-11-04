//
//  DSDockOverlay.m
//  DockScroller —— 闭环轮播 Dock 视图
//

#import "DSDockOverlay.h"
#import "DSCommon.h"
#import "DSConfig.h"
#import <math.h>

static char kDSBundleIDKey;

// UIButton 的 legacy setImage: 会让 imageView 按「图片原始尺寸」布局
// （我们传的是 120pt 的图），AspectFit 也约束不回来 → 显示尺寸失控。
// 这个子类把 imageView 强制铺满按钮，图标大小就完全由 frame 决定。
@interface DSIconButton : UIButton
@end

@implementation DSIconButton

- (void)layoutSubviews {
    [super layoutSubviews];
    self.imageView.frame = self.bounds;
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.imageView.clipsToBounds = YES;
}

@end

@interface DSDockOverlayView ()
- (void)ds_rebuild;
- (void)ds_normalizeOffset;
- (void)ds_snapAnimated:(BOOL)animated;
- (CGFloat)ds_resolvedIconSizeForSlot:(CGFloat)slot height:(CGFloat)height;
@end

@implementation DSDockOverlayView {
    UIView *_strip;
    NSMutableArray<UIButton *> *_buttons;
    NSArray<NSString *> *_apps;
    NSInteger _perPage;
    CGFloat _slot;
    CGFloat _copyWidth;
    NSInteger _copies;
    CFAbsoluteTime _lastLaunchAt;
    CGFloat _userIconSize;      // 负值 = 跟随系统
    CGFloat _userSpacing;       // 负值 = 自动
    CGFloat _systemIconSize;    // 从系统 Dock 实测到的图标边长
    NSString *_contentKey;      // 内容指纹（应用列表 + 每页数），变了就不该沿用旧位置
}

#pragma mark - 初始化

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    self.clipsToBounds = NO;
    _buttons = [NSMutableArray array];
    _perPage = 4;
    _slot = 0.0;
    _copyWidth = 1.0;
    _copies = 3;
    _ds_restoreLogical = -1.0;

    _scrollView = [[UIScrollView alloc] initWithFrame:self.bounds];
    _scrollView.backgroundColor = [UIColor clearColor];
    _scrollView.showsHorizontalScrollIndicator = NO;
    _scrollView.showsVerticalScrollIndicator = NO;
    _scrollView.alwaysBounceHorizontal = YES;
    _scrollView.decelerationRate = UIScrollViewDecelerationRateFast;
    _scrollView.clipsToBounds = YES;
    _scrollView.delegate = self;
    _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_scrollView];

    return self;
}

#pragma mark - 对外

- (void)reloadWithApps:(NSArray<NSString *> *)apps
               perPage:(NSInteger)perPage
              iconSize:(CGFloat)iconSize
               spacing:(CGFloat)spacing
         systemIconSize:(CGFloat)systemIconSize {
    _apps = [apps copy] ?: @[];
    _perPage = MAX(DSC_MIN_PER_PAGE, MIN(perPage, DSC_MAX_PER_PAGE));
    _userIconSize = iconSize;
    _userSpacing = spacing;
    _systemIconSize = systemIconSize;
    [self ds_rebuild];
}

#pragma mark - 构建内容

// 一页 N 个 → 槽宽 = 可视宽 / N；图标大小默认取系统 Dock 的实测值，
// 再被「用户设定的值」和「槽内不重叠」两者夹住。
- (CGFloat)ds_resolvedIconSizeForSlot:(CGFloat)slot height:(CGFloat)height {
    CGFloat maxIcon = slot - (_userSpacing >= 0.0 ? _userSpacing : 6.0) - 2.0;

    CGFloat icon = 0.0;
    if (_userIconSize > 0.0) {
        icon = _userIconSize;                       // 用户明确指定
    } else if (_systemIconSize >= 44.0) {
        icon = _systemIconSize;                     // 实测到系统值（太小视为脏数据）
    } else {
        icon = height - 24.0;                       // 兜底：按 Dock 高度推算（≈60pt）
    }

    icon = MIN(icon, maxIcon);
    icon = MIN(icon, height - 6.0);
    return MAX(24.0, icon);
}

- (CGFloat)ds_logicalOffset {
    if (!_scrollView.scrollEnabled) return -1.0;   // 应用数 ≤ 每页数：没有位置可记
    if (_copyWidth < 1.0) return -1.0;
    CGFloat x = _scrollView.contentOffset.x;
    CGFloat logical = fmod(x, _copyWidth);
    if (logical < 0.0) logical += _copyWidth;
    return logical;
}

- (void)ds_rebuild {
    // ⚠️ 位置记忆必须在这里取：重建会把 contentOffset 归位，
    //    不先记下来就会出现「点进 App 再退出，Dock 被踢回第一页」。
    NSString *newKey = [NSString stringWithFormat:@"%ld|%@",
                        (long)_perPage, [_apps componentsJoinedByString:@","]];
    BOOL sameContent = (_contentKey.length > 0 && [newKey isEqualToString:_contentKey]);
    CGFloat keep = sameContent ? [self ds_logicalOffset] : -1.0;
    if (keep < 0.0 && _ds_restoreLogical >= 0.0) keep = _ds_restoreLogical;
    _contentKey = [newKey copy];

    [_buttons removeAllObjects];
    [_strip removeFromSuperview];
    _strip = nil;

    CGRect bounds = self.bounds;
    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;
    if (width < 20.0 || height < 20.0) return;

    NSUInteger count = _apps.count;
    _strip = [[UIView alloc] initWithFrame:CGRectMake(0, 0, MAX(width, 1.0), MAX(height, 1.0))];
    _strip.backgroundColor = [UIColor clearColor];
    [_scrollView addSubview:_strip];

    if (count == 0) {
        _scrollView.scrollEnabled = NO;
        _scrollView.contentSize = _strip.frame.size;
        return;
    }

    // 槽宽：左右各留 8pt 内边距后等分（系统 Dock 图标区也是这样内缩的）
    CGFloat slot = (width - 16.0) / (CGFloat)_perPage;
    if (slot < 26.0) slot = 26.0;
    _slot = slot;

    CGFloat copyWidth = slot * (CGFloat)count;
    _copyWidth = copyWidth;

    // 应用数 ≤ 每页图标数 → 一屏就能全部放下，用户要求「不能滑动」。
    // 这时只铺一份、关掉手势，图标从左往右排（与系统 Dock 一致），
    // 也避免出现「同一图标重复出现好几遍」的怪样子。
    BOOL scrollable = (count > (NSUInteger)_perPage);
    _scrollView.scrollEnabled = scrollable;
    _scrollView.alwaysBounceHorizontal = scrollable;

    NSInteger copies;
    if (!scrollable) {
        copies = 1;
    } else {
        // 关键：副本数必须让「可视宽度 + 两侧各一份」都落在内容里，
        // 否则内容比屏幕短时右滑会撞到硬边、接不回开头（闭环断裂）。
        copies = (NSInteger)ceil(width / MAX(copyWidth, 1.0)) + 3;
        if (copies < 3) copies = 3;
        if (copies > 60) copies = 60;
    }
    _copies = copies;

    CGFloat totalWidth = copyWidth * (CGFloat)copies;
    _strip.frame = CGRectMake(0, 0, MAX(totalWidth, width), height);
    _scrollView.contentSize = scrollable ? CGSizeMake(totalWidth, height)
                                         : CGSizeMake(width, height);

    for (NSInteger copy = 0; copy < copies; copy++) {
        for (NSUInteger i = 0; i < count; i++) {
            NSString *bid = _apps[i];
            DSIconButton *button = (DSIconButton *)[DSIconButton buttonWithType:UIButtonTypeCustom];
            button.backgroundColor = [UIColor clearColor];
            button.adjustsImageWhenHighlighted = NO;
            [button setImage:DSIconForBundle(bid, 120.0) forState:UIControlStateNormal];
            button.imageView.contentMode = UIViewContentModeScaleAspectFit;
            button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
            button.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
            objc_setAssociatedObject(button, &kDSBundleIDKey, bid, OBJC_ASSOCIATION_COPY_NONATOMIC);
            [button addTarget:self action:@selector(ds_iconTapped:) forControlEvents:UIControlEventTouchUpInside];
            [_strip addSubview:button];
            [_buttons addObject:button];
        }
    }

    // 可滚动时起始位置放在第二份的开头：左右都还有充裕余量可以立刻拖动。
    // 不可滚动（应用数 ≤ 每页数）时干脆归零，图标从最左槽位开始排。
    if (scrollable) {
        CGFloat maxOffset = MAX(0.0, totalWidth - width);
        CGFloat startOffset = MIN(copyWidth, MAX(0.0, maxOffset));

        // 有位置记忆就放回原来的位置（仍落在第二份，左右都还有余量）
        if (keep >= 0.0 && copyWidth > 1.0) {
            CGFloat logical = fmod(keep, copyWidth);
            if (logical < 0.0) logical += copyWidth;
            startOffset = copyWidth + logical;
        }
        if (startOffset < 0.0) startOffset = 0.0;
        if (startOffset > maxOffset) startOffset = maxOffset;

        _scrollView.contentOffset = CGPointMake(startOffset, 0.0);
    } else {
        _scrollView.contentOffset = CGPointZero;
    }
    _ds_restoreLogical = -1.0;   // 用掉就清掉，避免影响下一次内容变更

    [self setNeedsLayout];
}

#pragma mark - 布局

- (void)layoutSubviews {
    [super layoutSubviews];

    self.scrollView.frame = self.bounds;

    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    if (width < 20.0 || height < 20.0) return;

    // 宽度变了（旋转 / 分屏 / 首次拿到真实 frame）→ 重算槽宽并重建
    CGFloat expected = (width - 16.0) / (CGFloat)MAX(DSC_MIN_PER_PAGE, _perPage);
    if (expected < 26.0) expected = 26.0;
    if (fabs(expected - _slot) > 0.5 && _apps.count > 0) {
        [self ds_rebuild];
        return;
    }

    CGFloat icon = [self ds_resolvedIconSizeForSlot:_slot height:height];
    CGFloat y = (height - icon) / 2.0;

    NSUInteger count = _apps.count;
    if (count == 0) return;

    for (NSUInteger idx = 0; idx < _buttons.count; idx++) {
        UIButton *button = _buttons[idx];
        NSInteger copy = (NSInteger)(idx / count);
        NSInteger pos = (NSInteger)(idx % count);
        CGFloat x = (CGFloat)copy * _copyWidth + 8.0 + (CGFloat)pos * _slot + (_slot - icon) / 2.0;
        button.frame = CGRectMake(x, y, icon, icon);
    }
}

#pragma mark - 闭环

- (void)ds_normalizeOffset {
    if (!_scrollView.scrollEnabled) return;   // 应用数 ≤ 每页数：本来就不该滑动
    CGFloat copyWidth = _copyWidth;
    if (copyWidth < 1.0) return;

    CGFloat contentWidth = _scrollView.contentSize.width;
    CGFloat maxOffset = MAX(0.0, contentWidth - _scrollView.bounds.size.width);
    CGFloat x = _scrollView.contentOffset.x;

    // 回弹阶段（负数 / 超过末尾）交给 UIScrollView 自己处理
    if (x < 0.0 || x > maxOffset) return;

    CGFloat lower = copyWidth;
    CGFloat upper = maxOffset - copyWidth;
    if (upper <= lower) return;   // 内容太短，保持静止（不会错位，只是不能闭环）

    if (x < lower) {
        _scrollView.contentOffset = CGPointMake(x + copyWidth, _scrollView.contentOffset.y);
    } else if (x > upper) {
        _scrollView.contentOffset = CGPointMake(x - copyWidth, _scrollView.contentOffset.y);
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [self ds_normalizeOffset];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    [self ds_normalizeOffset];
    [self ds_snapAnimated:YES];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) [self ds_snapAnimated:YES];
}

// 松手时吸附到最近的图标槽位；先夹住范围再取整，避免把 offset 吸到内容之外
- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView
                     withVelocity:(CGPoint)velocity
              targetContentOffset:(inout CGPoint *)targetContentOffset {
    if (!_scrollView.scrollEnabled) return;
    if (_slot < 1.0) return;
    CGFloat x = (*targetContentOffset).x;
    CGFloat maxX = MAX(0.0, scrollView.contentSize.width - scrollView.bounds.size.width);
    if (x < 0.0) x = 0.0;
    if (x > maxX) x = maxX;
    CGFloat snapped = round(x / _slot) * _slot;
    if (snapped < 0.0) snapped = 0.0;
    if (snapped > maxX) snapped = maxX;
    (*targetContentOffset).x = snapped;
}

- (void)ds_snapAnimated:(BOOL)animated {
    if (!_scrollView.scrollEnabled) return;   // 不可滚动时没有槽位需要吸附
    if (_slot < 1.0) return;
    CGFloat x = _scrollView.contentOffset.x;
    CGFloat snapped = round(x / _slot) * _slot;
    if (fabs(snapped - x) < 0.5) return;
    [_scrollView setContentOffset:CGPointMake(snapped, 0.0) animated:animated];
}

#pragma mark - 点击

- (void)ds_iconTapped:(UIButton *)sender {
    NSString *bid = objc_getAssociatedObject(sender, &kDSBundleIDKey);
    if (bid.length == 0) return;

    // 防连点：连点会堆叠多个启动请求，系统转场期间最容易卡
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (_lastLaunchAt > 0.0 && now - _lastLaunchAt < 1.2) return;
    _lastLaunchAt = now;

    // 给一点按下反馈：启动请求是异步的，转场前有短暂空档
    sender.alpha = 0.45;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sender.alpha = 1.0;
    });

    DSLaunchBundle(bid);
}

#pragma mark - 触摸

// 只接管 Dock 区域内的触摸，其余返回 nil 让 SpringBoard 自己处理
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *view = [super hitTest:point withEvent:event];
    return view == self ? nil : view;
}

@end
