#import "FinderFrameworkProbe.h"
#import <AppKit/AppKit.h>
#import <FinderSync/FinderSync.h>
#import <objc/runtime.h>

// 系统内部接口只用于测试，不链接进发行应用；通过运行时检测保证失败可见。
@interface NSObject (MenuGitFrameworkTesting)
- (id)initWithInputItems:(NSArray *)items;
- (void)setUpSingletonAndHostPrincipal;
- (void)requestMenuItemsForTarget:(NSDictionary *)target selectedItems:(NSArray *)items
                           menu:(NSUInteger)kind result:(void(^)(id))result;
- (void)executeCommandWithMenuItemDictionary:(NSDictionary *)item
                                    target:(NSDictionary *)target items:(NSArray *)items;
@end

NSArray *MenuGitRequestSerializedMenu(Class principalClass, NSURL *target,
                                     NSArray<NSURL *> *selected, NSUInteger kind,
                                     BOOL dispatchFirstAction) {
    Class contextClass = NSClassFromString(@"FIFinderSyncExtension");
    if (!contextClass || ![contextClass instancesRespondToSelector:@selector(requestMenuItemsForTarget:selectedItems:menu:result:)]) {
        fprintf(stderr, "Native FinderSync test interface is unavailable\n");
        return nil;
    }
    id context = [[contextClass alloc] initWithInputItems:@[]];
    [context setUpSingletonAndHostPrincipal];
    __block id principal = nil;
    Method delegateMethod = class_getInstanceMethod(contextClass, @selector(delegate));
    if (!delegateMethod) return nil;
    IMP original = method_getImplementation(delegateMethod);
    IMP replacement = imp_implementationWithBlock(^id(id instance) { return principal; });
    class_replaceMethod(contextClass, @selector(delegate), replacement, method_getTypeEncoding(delegateMethod));
    __block NSArray *payload = nil;
    @try {
        principal = [principalClass new];
        NSDictionary *targetItem = @{ @"URL": target.absoluteString };
        NSMutableArray *selectedItems = [NSMutableArray array];
        for (NSURL *url in selected) [selectedItems addObject:@{ @"URL": url.absoluteString }];
        [context requestMenuItemsForTarget:targetItem selectedItems:selectedItems menu:kind result:^(id result) {
            if ([result isKindOfClass:NSArray.class]) payload = result;
        }];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
        while (!payload && deadline.timeIntervalSinceNow > 0)
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        if (dispatchFirstAction && payload.count > 0) {
            NSDictionary *parent = payload[0];
            NSArray *submenu = parent[@"submenu"];
            if (submenu.count > 0)
                [context executeCommandWithMenuItemDictionary:submenu[0] target:targetItem items:selectedItems];
        }
    } @catch (NSException *exception) {
        fprintf(stderr, "Native FinderSync test failed: %s\n", exception.reason.UTF8String);
        payload = nil;
    } @finally {
        class_replaceMethod(contextClass, @selector(delegate), original, method_getTypeEncoding(delegateMethod));
        imp_removeBlock(replacement);
    }
    return payload;
}
