#import "DSCommon.h"
#import "DSConfig.h"
#import "DSDockManager.h"

// 本项目【不 hook 任何私有类】：
// Dock 的私有类名跨版本会变，而 Logos 对「类/方法不存在」是静默丢弃的
// （编译过、CI 绿、永远不执行）。所以只用「运行时找视图 + 自绘轮播」。
%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (![bundleID isEqualToString:@"com.apple.springboard"]) return;

        DSLog(@"===== Dock 轮播 %@ 已注入 SpringBoard（pid=%d）=====", DSCVersion(), (int)getpid());

        // SpringBoard 启动时视图树还没建好，延后一点再开始轮询
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[DSDockManager shared] start];
        });
    }
}
