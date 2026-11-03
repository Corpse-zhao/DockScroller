//
//  DSDockManager.h
//  DockScroller —— Dock 检测、安装/卸载轮播视图、隐藏原生 Dock 图标
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface DSDockManager : NSObject

+ (instancetype)shared;

// 由 Tweak.x 的 %ctor 调用；内部自己起 1 秒轮询
- (void)start;

@end
