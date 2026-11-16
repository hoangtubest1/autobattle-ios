// AutoClicker.m - v2
// Unity-compatible touch simulation via UITouch injection
// Inject via TrollFools - no Substrate needed

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

// ─── UITouch Injection (Unity-compatible) ────────────────────────────────────
// Unity hooks UIApplication.sendEvent: để xử lý touch
// Cách này hoạt động với Unity vì Unity implement touchesBegan/Moved/Ended trên UIView

static void sendFakeTouch(CGPoint point) {
    UIApplication *app = [UIApplication sharedApplication];

    // Tìm game window (bỏ qua PassthroughWindow của chúng ta)
    UIWindow *gameWindow = nil;
    for (UIWindow *w in app.windows) {
        // Lấy window đầu tiên không phải của chúng ta
        if (!w.isHidden && [NSStringFromClass([w class]) isEqualToString:@"UIWindow"]) {
            gameWindow = w;
            break;
        }
    }
    if (!gameWindow) {
        // Fallback: lấy keyWindow
        for (UIWindow *w in app.windows) {
            if (w.isKeyWindow) { gameWindow = w; break; }
        }
    }
    if (!gameWindow) {
        NSLog(@"[AutoClicker] No game window found!");
        return;
    }

    // Tìm view tại vị trí click
    UIView *hitView = [gameWindow hitTest:point withEvent:nil];
    if (!hitView) hitView = gameWindow;

    // Tạo UITouch
    UITouch *touch = [UITouch new];
    [touch setValue:@(UITouchPhaseBegan)   forKey:@"phase"];
    [touch setValue:@(1)                   forKey:@"tapCount"];
    [touch setValue:@(CACurrentMediaTime()) forKey:@"timestamp"];
    [touch setValue:hitView                forKey:@"view"];
    [touch setValue:gameWindow             forKey:@"window"];
    [touch setValue:[NSValue valueWithCGPoint:point] forKey:@"locationInWindow"];
    [touch setValue:[NSValue valueWithCGPoint:point] forKey:@"previousLocationInWindow"];
    [touch setValue:@(UITouchTypeDirect)   forKey:@"type"];

    // Lấy UITouchesEvent từ app (private API)
    SEL eventSel = NSSelectorFromString(@"_touchesEvent");
    if (![app respondsToSelector:eventSel]) {
        NSLog(@"[AutoClicker] _touchesEvent not found — trying fallback");
        // Fallback: gửi trực tiếp qua responder chain
        [hitView touchesBegan:[NSSet setWithObject:touch] withEvent:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
            [hitView touchesEnded:[NSSet setWithObject:touch] withEvent:nil];
        });
        return;
    }

    NSMethodSignature *sig = [app methodSignatureForSelector:eventSel];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:app];
    [inv setSelector:eventSel];
    [inv invoke];

    UIEvent *event = nil;
    [inv getReturnValue:&event];

    if (!event) {
        NSLog(@"[AutoClicker] Could not get UITouchesEvent");
        return;
    }

    // Thêm touch vào event
    SEL addSel = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");
    if ([event respondsToSelector:addSel]) {
        NSMethodSignature *addSig = [event methodSignatureForSelector:addSel];
        NSInvocation *addInv = [NSInvocation invocationWithMethodSignature:addSig];
        [addInv setTarget:event];
        [addInv setSelector:addSel];
        [addInv setArgument:&touch atIndex:2];
        BOOL delayed = NO;
        [addInv setArgument:&delayed atIndex:3];
        [addInv invoke];
    } else {
        NSLog(@"[AutoClicker] _addTouch:forDelayedDelivery: not found");
    }

    // Gửi touch began
    [app sendEvent:event];
    NSLog(@"[AutoClicker] Sent touchBegan at (%.0f, %.0f)", point.x, point.y);

    // Gửi touch ended sau 80ms
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        [touch setValue:@(UITouchPhaseEnded)    forKey:@"phase"];
        [touch setValue:@(CACurrentMediaTime())  forKey:@"timestamp"];
        [app sendEvent:event];

        // Dọn dẹp touches
        SEL cleanSel = NSSelectorFromString(@"_removeAllTouches");
        if ([event respondsToSelector:cleanSel]) {
            [event performSelector:cleanSel];
        }
        NSLog(@"[AutoClicker] Sent touchEnded");
    });
}

// ─── Visual Flash (xác nhận vị trí click) ───────────────────────────────────
static void flashAt(CGPoint point, UIView *parentView) {
    UIView *flash = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    flash.center = point;
    flash.backgroundColor = [UIColor colorWithRed:1 green:1 blue:0 alpha:0.8];
    flash.layer.cornerRadius = 15;
    flash.userInteractionEnabled = NO;
    [parentView addSubview:flash];

    [UIView animateWithDuration:0.4 animations:^{
        flash.alpha = 0;
        flash.transform = CGAffineTransformMakeScale(2, 2);
    } completion:^(BOOL done) {
        [flash removeFromSuperview];
    }];
}

// ─── Passthrough UI ──────────────────────────────────────────────────────────

@interface PassthroughView : UIView
@end
@implementation PassthroughView
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return (v == self) ? nil : v;
}
@end

@interface PassthroughWindow : UIWindow
@end
@implementation PassthroughWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return (v == self) ? nil : v;
}
@end

// ─── Controller ─────────────────────────────────────────────────────────────

@interface ACController : NSObject
@property (nonatomic) BOOL      isRunning;
@property (nonatomic) CGPoint   clickTarget;
@property (nonatomic, strong) NSTimer   *timer;
@property (nonatomic, strong) UIWindow  *overlayWindow;
@property (nonatomic, strong) UIButton  *btn;
@property (nonatomic, strong) UIView    *dot;      // chấm đỏ = vị trí sẽ click
@property (nonatomic, strong) UILabel  *label;    // hiển thị tọa độ
+ (instancetype)shared;
- (void)setup;
@end

@implementation ACController

+ (instancetype)shared {
    static ACController *i; static dispatch_once_t t;
    dispatch_once(&t, ^{ i = [ACController new]; });
    return i;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        CGSize s = UIScreen.mainScreen.bounds.size;
        // Mặc định: giữa màn hình, 80% từ trên xuống
        _clickTarget = CGPointMake(s.width * 0.5, s.height * 0.80);
    }
    return self;
}

- (void)setup {
    // Tạo overlay window
    PassthroughWindow *win;
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive)
        { scene = (UIWindowScene *)s; break; }

    win = scene
        ? [[PassthroughWindow alloc] initWithWindowScene:scene]
        : [[PassthroughWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

    win.windowLevel = UIWindowLevelAlert + 1000;
    win.backgroundColor = UIColor.clearColor;
    win.hidden = NO;  // KHÔNG makeKeyAndVisible
    self.overlayWindow = win;

    UIViewController *vc = [UIViewController new];
    PassthroughView *root = [[PassthroughView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    root.backgroundColor = UIColor.clearColor;
    vc.view = root;
    win.rootViewController = vc;

    // ── Nút điều khiển ──
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(10, 130, 54, 54);
    b.backgroundColor = [UIColor colorWithRed:0.1 green:0.5 blue:1 alpha:0.9];
    b.layer.cornerRadius = 27;
    b.layer.borderWidth = 2; b.layer.borderColor = UIColor.whiteColor.CGColor;
    b.layer.shadowOpacity = 0.4; b.layer.shadowRadius = 4;
    b.layer.shadowOffset = CGSizeMake(0,2); b.layer.shadowColor = UIColor.blackColor.CGColor;
    b.titleLabel.font = [UIFont systemFontOfSize:18];
    [b setTitle:@"▶" forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [b addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(onLongPress:)];
    lp.minimumPressDuration = 0.7;
    [b addGestureRecognizer:lp];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(onPan:)];
    [b addGestureRecognizer:pan];

    self.btn = b;
    [root addSubview:b];

    // ── Chấm đỏ (vị trí click) ──
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0,0,16,16)];
    dot.center = self.clickTarget;
    dot.backgroundColor = [UIColor colorWithRed:1 green:0.15 blue:0.15 alpha:0.85];
    dot.layer.cornerRadius = 8;
    dot.layer.borderColor = UIColor.whiteColor.CGColor;
    dot.layer.borderWidth = 1.5;
    dot.userInteractionEnabled = NO;
    self.dot = dot;
    [root addSubview:dot];

    // ── Label tọa độ ──
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0,0,120,20)];
    lbl.center = CGPointMake(b.center.x + 70, b.center.y);
    lbl.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightMedium];
    lbl.textColor = UIColor.whiteColor;
    lbl.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    lbl.layer.cornerRadius = 4; lbl.clipsToBounds = YES;
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.text = [NSString stringWithFormat:@"(%.0f,%.0f)", self.clickTarget.x, self.clickTarget.y];
    lbl.userInteractionEnabled = NO;
    self.label = lbl;
    [root addSubview:lbl];

    NSLog(@"[AutoClicker v2] UI ready. Default target: (%.0f,%.0f)",
          self.clickTarget.x, self.clickTarget.y);
}

- (void)onTap {
    self.isRunning = !self.isRunning;
    if (self.isRunning) {
        self.btn.backgroundColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:0.9];
        [self.btn setTitle:@"⏹" forState:UIControlStateNormal];
        self.timer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                      target:self
                                                    selector:@selector(doClick)
                                                    userInfo:nil
                                                     repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
        // Click ngay lần đầu
        [self doClick];
        NSLog(@"[AutoClicker] ▶ STARTED at (%.0f,%.0f)", self.clickTarget.x, self.clickTarget.y);
    } else {
        self.btn.backgroundColor = [UIColor colorWithRed:0.1 green:0.5 blue:1 alpha:0.9];
        [self.btn setTitle:@"▶" forState:UIControlStateNormal];
        [self.timer invalidate]; self.timer = nil;
        NSLog(@"[AutoClicker] ⏹ STOPPED");
    }
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    // Đặt target = vị trí nút hiện tại
    CGPoint c = self.btn.center;
    self.clickTarget = c;
    self.dot.center  = c;
    self.label.text  = [NSString stringWithFormat:@"(%.0f,%.0f)", c.x, c.y];

    // Hiệu ứng xác nhận
    [UIView animateWithDuration:0.1 animations:^{
        self.btn.transform = CGAffineTransformMakeScale(1.4, 1.4);
    } completion:^(BOOL f) {
        [UIView animateWithDuration:0.1 animations:^{
            self.btn.transform = CGAffineTransformIdentity;
        }];
    }];
    NSLog(@"[AutoClicker] 🎯 Target saved: (%.0f,%.0f)", c.x, c.y);
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:g.view.superview];
    CGPoint c = g.view.center;
    c.x += d.x; c.y += d.y;
    g.view.center = c;
    [g setTranslation:CGPointZero inView:g.view.superview];
    // Cập nhật label vị trí nút
    self.label.center = CGPointMake(c.x + 70, c.y);
}

- (void)doClick {
    // Flash vàng để xác nhận vị trí click
    flashAt(self.clickTarget, self.overlayWindow.rootViewController.view);
    // Gửi fake touch
    sendFakeTouch(self.clickTarget);
}

@end

// ─── Entry Point ─────────────────────────────────────────────────────────────

__attribute__((constructor))
static void acInit(void) {
    NSLog(@"[AutoClicker v2] Loaded!");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[ACController shared] setup];
        NSLog(@"[AutoClicker v2] UI initialized!");
    });
}
