/**
 * dp_scroll.m  —  大众点评爬虫助手 (纯原生，无 Frida)
 * ════════════════════════════════════════════════════════
 *
 * 功能:
 *   ① DYLD_INTERPOSE 劫持 SecTrustEvaluate* → SSL 证书绑定绕过
 *      (在 dyld 加载阶段替换符号，不修改任何代码内存，绝不触发反调试)
 *   ② 启动 5 秒后自动上滑，间隔约 2~4 秒
 *   ③ 摇一摇手机 → 暂停 / 继续自动滑动
 *
 * 编译 (由 GitHub Actions 自动完成，见 .github/workflows/build.yml):
 *   xcrun -sdk iphoneos clang         \
 *     -arch arm64 -arch arm64e        \
 *     -miphoneos-version-min=14.0     \
 *     -framework UIKit                \
 *     -framework Foundation           \
 *     -framework Security             \
 *     -shared                         \
 *     -Wl,-install_name,@executable_path/Frameworks/dp_scroll.dylib \
 *     -o dp_scroll.dylib dp_scroll.m
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <Security/Security.h>
#include <dispatch/dispatch.h>

/* ── DYLD_INTERPOSE 宏 ─────────────────────────────────── */
#ifndef DYLD_INTERPOSE
#define DYLD_INTERPOSE(_new, _old)                                  \
  __attribute__((used))                                             \
  __attribute__((section("__DATA,__interpose")))                    \
  static struct { const void *n; const void *o; } _i_##_old =      \
    { (const void *)&(_new), (const void *)&(_old) }
#endif

/* ════════════════════════════════════════════════════════
 * ① SSL 证书绑定绕过
 *    用 DYLD_INTERPOSE 在符号层面替换 Security 函数，
 *    无任何内存补丁，App 无法通过代码完整性校验检测到
 * ════════════════════════════════════════════════════════ */

static Boolean dp_SecTrustEvaluateWithError(SecTrustRef trust,
                                             CFErrorRef *error) {
    if (error) *error = NULL;
    return YES;  /* 永远返回"信任" */
}

static OSStatus dp_SecTrustEvaluate(SecTrustRef trust,
                                     SecTrustResultType *result) {
    if (result) *result = kSecTrustResultProceed;
    return errSecSuccess;
}

DYLD_INTERPOSE(dp_SecTrustEvaluateWithError, SecTrustEvaluateWithError)
DYLD_INTERPOSE(dp_SecTrustEvaluate,          SecTrustEvaluate)

/* ════════════════════════════════════════════════════════
 * ② 自动滑动
 * ════════════════════════════════════════════════════════ */

static volatile BOOL     g_on  = NO;
static dispatch_source_t g_src = NULL;

/* 在当前屏幕中心找面积最大的可见 UIScrollView */
static UIScrollView *dp_best_sv(void) {
    UIWindow *win = UIApplication.sharedApplication.keyWindow;
    if (!win) return nil;

    CGSize  sc  = UIScreen.mainScreen.bounds.size;
    CGPoint ctr = CGPointMake(sc.width * .5f, sc.height * .5f);

    NSMutableArray *q = [NSMutableArray arrayWithObject:win];
    UIScrollView   *best = nil;
    CGFloat         bA   = 0;

    while (q.count) {
        UIView *v = q[0]; [q removeObjectAtIndex:0];
        if ([v isKindOfClass:UIScrollView.class]
            && !v.hidden && v.alpha > .05f
            && v.frame.size.height > 100
            && CGRectContainsPoint(v.frame, ctr)) {
            CGFloat a = v.frame.size.width * v.frame.size.height;
            if (a > bA) { best = (UIScrollView *)v; bA = a; }
        }
        for (UIView *s in v.subviews) [q addObject:s];
    }
    return best;
}

static void dp_swipe(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIScrollView *sv = dp_best_sv();
        if (!sv) return;

        CGFloat h    = UIScreen.mainScreen.bounds.size.height;
        CGFloat amt  = h * (.28f + arc4random_uniform(32) / 100.f);
        CGFloat maxY = sv.contentSize.height - sv.frame.size.height;
        CGFloat newY = sv.contentOffset.y + amt;

        if (maxY > 0 && newY > maxY)
            [sv setContentOffset:CGPointZero animated:NO];   /* 回顶 */
        else
            [sv setContentOffset:CGPointMake(sv.contentOffset.x, newY)
                        animated:YES];
    });
}

static void dp_start(void) {
    if (g_on) return;
    g_on = YES;

    dispatch_queue_t q =
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
    g_src = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);

    /* 每 2~4 秒滑一次 (3s base, 1s leeway 带来随机感) */
    dispatch_source_set_timer(g_src, DISPATCH_TIME_NOW,
                              3 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(g_src, ^{
        if (g_on) dp_swipe();
    });
    dispatch_resume(g_src);
}

static void dp_stop(void) {
    if (!g_on) return;
    g_on = NO;
    if (g_src) { dispatch_source_cancel(g_src); g_src = NULL; }
}

static void dp_toggle(void) { g_on ? dp_stop() : dp_start(); }

/* ════════════════════════════════════════════════════════
 * ③ 摇一摇切换 (UIWindow Method Swizzling)
 * ════════════════════════════════════════════════════════ */

@interface UIWindow (DPShake) @end

@implementation UIWindow (DPShake)

+ (void)load {
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{
        SEL origSel = @selector(motionEnded:withEvent:);
        SEL newSel  = @selector(dp_motionEnded:withEvent:);
        Method origM = class_getInstanceMethod(self, origSel);
        Method newM  = class_getInstanceMethod(self, newSel);
        if (origM && newM)
            method_exchangeImplementations(origM, newM);
        else if (newM)
            class_addMethod(self, origSel,
                            method_getImplementation(newM),
                            method_getTypeEncoding(newM));
    });
}

- (void)dp_motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) dp_toggle();
    [self dp_motionEnded:motion withEvent:event]; /* 调用原始实现 */
}

@end

/* ════════════════════════════════════════════════════════
 * Dylib 构造函数 — app 启动 5 秒后开始自动滑动
 * ════════════════════════════════════════════════════════ */

__attribute__((constructor)) static void dp_init(void) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
        dispatch_get_main_queue(),
        ^{ dp_start(); }
    );
}

