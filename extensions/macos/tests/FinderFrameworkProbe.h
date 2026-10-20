#import <Foundation/Foundation.h>

// 仅后台测试使用：系统的 FinderSync 菜单序列化与动作分派路径。
NSArray *MenuGitRequestSerializedMenu(Class principalClass, NSURL *target,
                                     NSArray<NSURL *> *selected, NSUInteger kind,
                                     BOOL dispatchFirstAction);
