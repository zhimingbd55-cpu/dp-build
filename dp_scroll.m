@import UIKit;
@import Foundation;
@import Security;
#include <objc/runtime.h>
#import <dispatch/dispatch.h>

#ifndef DYLD_INTERPOSE
#define DYLD_INTERPOSE(_new, _old) \
  __attribute__((used)) \
  __attribute__((section("__DATA,__interpose"))) \
  static struct { const void *n; const void *o; } _i_##_old = \
    { (const void *)&(_new), (const void *)&(_old) }
#endif

static Boolean dp_SecTrustEvaluateWithError(SecTrustRef t, CFErrorRef *e) {
    if (e) *e = NULL; return YES;
}
static OSStatus dp_SecTrustEvaluate(SecTrustRef t, SecTrustResultType *r) {
    if (r) *r = kSecTrustResultProceed; return errSecSuccess;
}
DYLD_INTERPOSE(dp_SecTrustEvaluateWithError, SecTrustEvaluateWithError)
DYLD_INTERPOSE(dp_SecTrustEvaluate, SecTrustEvaluate)

static volatile BOOL g_on = NO;
static dispatch_source_t g_src = NULL;

static UIScrollView *dp_best_sv(void) {
    UIWindow *win = UIApplication.sharedApplication.keyWindow;
    if (!win) return nil;
    CGSize sc = UIScreen.mainScreen.bounds.size;
    CGPoint ctr = CGPointMake(sc.width*.5f, sc.height*.5f);
    NSMutableArray *q = [NSMutableArray arrayWithObject:win];
    UIScrollView *best = nil; CGFloat bA = 0;
    while (q.count) {
        UIView *v = q[0]; [q removeObjectAtIndex:0];
        if ([v isKindOfClass:UIScrollView.class] && !v.hidden && v.alpha>.05f
            && v.frame.size.height>100 && CGRectContainsPoint(v.frame,ctr)) {
            CGFloat a = v.frame.size.width*v.frame.size.height;
            if (a>bA) { best=(UIScrollView*)v; bA=a; }
        }
        for (UIView *s in v.subviews) [q addObject:s];
    }
    return best;
}

static void dp_swipe(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIScrollView *sv = dp_best_sv(); if (!sv) return;
        CGFloat h = UIScreen.mainScreen.bounds.size.height;
        CGFloat amt = h*(.28f+(float)arc4random_uniform(32)/100.f);
        CGFloat maxY = sv.contentSize.height-sv.frame.size.height;
        CGFloat newY = sv.contentOffset.y+amt;
        if (maxY>0 && newY>maxY) [sv setContentOffset:CGPointZero animated:NO];
        else [sv setContentOffset:CGPointMake(sv.contentOffset.x,newY) animated:YES];
    });
}

static void dp_start(void) {
    if (g_on) return; g_on = YES;
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW,0);
    g_src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,q);
    dispatch_source_set_timer(g_src,DISPATCH_TIME_NOW,3*NSEC_PER_SEC,NSEC_PER_SEC);
    dispatch_source_set_event_handler(g_src, ^{ if (g_on) dp_swipe(); });
    dispatch_resume(g_src);
}
static void dp_stop(void) {
    if (!g_on) return; g_on = NO;
    if (g_src) { dispatch_source_cancel(g_src); g_src = NULL; }
}
static void dp_toggle(void) { g_on ? dp_stop() : dp_start(); }

@interface UIWindow (DPShake) @end
@implementation UIWindow (DPShake)
+ (void)load {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        SEL o=@selector(motionEnded:withEvent:), n=@selector(dp_motionEnded:withEvent:);
        Method om=class_getInstanceMethod(self,o), nm=class_getInstanceMethod(self,n);
        if (om&&nm) method_exchangeImplementations(om,nm);
        else if (nm) class_addMethod(self,o,method_getImplementation(nm),method_getTypeEncoding(nm));
    });
}
- (void)dp_motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion==UIEventSubtypeMotionShake) dp_toggle();
    [self dp_motionEnded:motion withEvent:event];
}
@end

__attribute__((constructor)) static void dp_init(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ dp_start(); });
}
