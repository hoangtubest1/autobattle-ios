// AutoClicker.m - v3 (stable, no crash)
// Dùng direct responder chain + try/catch để tránh văng game

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ─── Touch Simulation (safe, no crash) ───────────────────────────────────────

static void sendFakeTouch(CGPoint point) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];

        // Tìm game window (không phải PassthroughWindow)
        UIWindow *gameWin = nil;
        for (UIWindow *w in app.windows) {
            if (!w.isHidden && [NSStringFromClass([w class]) isEqualToString:@"UIWindow"]) {
                gameWin = w; break;
            }
        }
        if (!gameWin) {
            for (UIWindow *w in app.windows) {
                if (w.isKeyWindow) { gameWin = w; break; }
            }
        }
        if (!gameWin) return;

        // Hit test để lấy đúng view
        UIView *hitView = [gameWin hitTest:point withEvent:nil] ?: gameWin;

        // Tạo UITouch mới mỗi lần (không reuse tránh crash)
        UITouch *touch = [UITouch new];
        [touch setValue:@(UITouchPhaseBegan)      forKey:@"phase"];
        [touch setValue:@(1)                       forKey:@"tapCount"];
        [touch setValue:@(CACurrentMediaTime())    forKey:@"timestamp"];
        [touch setValue:hitView                    forKey:@"view"];
        [touch setValue:gameWin                    forKey:@"window"];
        [touch setValue:[NSValue valueWithCGPoint:point] forKey:@"locationInWindow"];
        [touch setValue:[NSValue valueWithCGPoint:point] forKey:@"previousLocationInWindow"];
        [touch setValue:@(UITouchTypeDirect)       forKey:@"type"];

        NSSet *touches = [NSSet setWithObject:touch];

        // --- Phương pháp 1: UITouchesEvent (Unity-compatible) ---
        BOOL method1OK = NO;
        SEL eventSel = NSSelectorFromString(@"_touchesEvent");
        if ([app respondsToSelector:eventSel]) {
            @try {
                NSMethodSignature *sig = [app methodSignatureForSelector:eventSel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:app]; [inv setSelector:eventSel]; [inv invoke];

                UIEvent *event = nil;
                [inv getReturnValue:&event];

                if (event) {
                    SEL addSel = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");
                    if ([event respondsToSelector:addSel]) {
                        NSMethodSignature *addSig = [event methodSignatureForSelector:addSel];
                        NSInvocation *addInv = [NSInvocation invocationWithMethodSignature:addSig];
                        [addInv setTarget:event]; [addInv setSelector:addSel];
                        [addInv setArgument:&touch atIndex:2];
                        BOOL delayed = NO; [addInv setArgument:&delayed atIndex:3];
                        [addInv invoke];
                    }
                    [app sendEvent:event];
                    method1OK = YES;

                    // Touch end sau 60ms
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC),
                                   dispatch_get_main_queue(), ^{
                        @try {
                            UITouch *endTouch = [UITouch new];
                            [endTouch setValue:@(UITouchPhaseEnded)      forKey:@"phase"];
                            [endTouch setValue:@(1)                       forKey:@"tapCount"];
                            [endTouch setValue:@(CACurrentMediaTime())    forKey:@"timestamp"];
                            [endTouch setValue:hitView                    forKey:@"view"];
                            [endTouch setValue:gameWin                    forKey:@"window"];
                            [endTouch setValue:[NSValue valueWithCGPoint:point] forKey:@"locationInWindow"];
                            [endTouch setValue:[NSValue valueWithCGPoint:point] forKey:@"previousLocationInWindow"];
                            [endTouch setValue:@(UITouchTypeDirect)       forKey:@"type"];

                            SEL addSel2 = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");
                            if ([event respondsToSelector:addSel2]) {
                                NSMethodSignature *s2 = [event methodSignatureForSelector:addSel2];
                                NSInvocation *i2 = [NSInvocation invocationWithMethodSignature:s2];
                                [i2 setTarget:event]; [i2 setSelector:addSel2];
                                [i2 setArgument:&endTouch atIndex:2];
                                BOOL d = NO; [i2 setArgument:&d atIndex:3];
                                [i2 invoke];
                            }
                            [app sendEvent:event];

                            // Dọn event (KHÔNG dùng _removeAllTouches → crash)
                            SEL clearSel = NSSelectorFromString(@"_removeTouches:");
                            if ([event respondsToSelector:clearSel]) {
                                [event performSelector:clearSel withObject:touches];
                            }
                        } @catch (NSException *e) {
                            NSLog(@"[AutoClicker] touchEnd exception: %@", e);
                        }
                    });
                }
            } @catch (NSException *e) {
                NSLog(@"[AutoClicker] Method1 exception: %@", e);
                method1OK = NO;
            }
        }

        // --- Phương pháp 2: Direct responder chain (fallback) ---
        if (!method1OK) {
            @try {
                [hitView touchesBegan:touches withEvent:nil];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    @try {
                        [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
                        [touch setValue:@(CACurrentMediaTime()) forKey:@"timestamp"];
                        [hitView touchesEnded:[NSSet setWithObject:touch] withEvent:nil];
                    } @catch (NSException *e) {
                        NSLog(@"[AutoClicker] Method2 end exception: %@", e);
                    }
                });
            } @catch (NSException *e) {
                NSLog(@"[AutoClicker] Method2 exception: %@", e);
            }
        }

    } @catch (NSException *ex) {
        NSLog(@"[AutoClicker] sendFakeTouch exception: %@", ex);
    }
}

// ─── Visual Flash ─────────────────────────────────────────────────────────────

static void flashAt(CGPoint pt, UIView *parent) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *f = [[UIView alloc] initWithFrame:CGRectMake(0,0,28,28)];
        f.center = pt;
        f.backgroundColor = [UIColor colorWithRed:1 green:0.9 blue:0 alpha:0.85];
        f.layer.cornerRadius = 14;
        f.userInteractionEnabled = NO;
        [parent addSubview:f];
        [UIView animateWithDuration:0.35 animations:^{
            f.alpha = 0;
            f.transform = CGAffineTransformMakeScale(2.5, 2.5);
        } completion:^(BOOL done) { [f removeFromSuperview]; }];
    });
}

// ─── Passthrough UI ───────────────────────────────────────────────────────────

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

// ─── Main Controller ──────────────────────────────────────────────────────────

@interface ACController : NSObject
@property (nonatomic) BOOL    isRunning;
@property (nonatomic) CGPoint target;
@property (nonatomic, strong) NSTimer   *timer;
@property (nonatomic, strong) UIWindow  *overlay;
@property (nonatomic, strong) UIButton  *btn;
@property (nonatomic, strong) UIView    *dot;
@property (nonatomic, strong) UILabel   *coordLabel;
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
        _target = CGPointMake(s.width * 0.5, s.height * 0.80);
    }
    return self;
}

- (void)setup {
    PassthroughWindow *win;
    UIWindowScene *sc = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive)
        { sc = (UIWindowScene *)s; break; }

    win = sc ? [[PassthroughWindow alloc] initWithWindowScene:sc]
             : [[PassthroughWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    win.windowLevel = UIWindowLevelAlert + 1000;
    win.backgroundColor = UIColor.clearColor;
    win.hidden = NO;
    self.overlay = win;

    UIViewController *vc = [UIViewController new];
    PassthroughView *root = [[PassthroughView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    root.backgroundColor = UIColor.clearColor;
    vc.view = root;
    win.rootViewController = vc;

    // Nút ▶/⏹
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(10, 140, 54, 54);
    [self applyStyle:b on:NO];
    [b addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(longPress:)];
    lp.minimumPressDuration = 0.7;
    [b addGestureRecognizer:lp];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(pan:)];
    [b addGestureRecognizer:pan];
    self.btn = b;
    [root addSubview:b];

    // Chấm đỏ (điểm click)
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0,0,16,16)];
    dot.center = self.target;
    dot.backgroundColor = [UIColor colorWithRed:1 green:0.15 blue:0.15 alpha:0.85];
    dot.layer.cornerRadius = 8;
    dot.layer.borderColor = UIColor.whiteColor.CGColor;
    dot.layer.borderWidth = 1.5;
    dot.userInteractionEnabled = NO;
    self.dot = dot;
    [root addSubview:dot];

    // Label tọa độ
    UILabel *lbl = [UILabel new];
    lbl.frame = CGRectMake(70, 149, 110, 22);
    lbl.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    lbl.textColor = UIColor.whiteColor;
    lbl.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    lbl.layer.cornerRadius = 4; lbl.clipsToBounds = YES;
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.text = [NSString stringWithFormat:@"(%.0f, %.0f)", self.target.x, self.target.y];
    lbl.userInteractionEnabled = NO;
    self.coordLabel = lbl;
    [root addSubview:lbl];
}

- (void)applyStyle:(UIButton *)b on:(BOOL)on {
    b.layer.cornerRadius = 27;
    b.layer.borderWidth = 2;
    b.layer.borderColor = UIColor.whiteColor.CGColor;
    b.layer.shadowColor = UIColor.blackColor.CGColor;
    b.layer.shadowOpacity = 0.4;
    b.layer.shadowRadius = 4;
    b.layer.shadowOffset = CGSizeMake(0, 2);
    b.titleLabel.font = [UIFont systemFontOfSize:18];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor = on
        ? [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:0.9]
        : [UIColor colorWithRed:0.1 green:0.5 blue:1.0 alpha:0.9];
    [b setTitle:(on ? @"⏹" : @"▶") forState:UIControlStateNormal];
}

- (void)toggle {
    self.isRunning = !self.isRunning;
    [self applyStyle:self.btn on:self.isRunning];
    if (self.isRunning) {
        // Click ngay lần đầu, sau đó mỗi 2.5 giây
        [self doClick];
        self.timer = [NSTimer scheduledTimerWithTimeInterval:2.5
                                                      target:self
                                                    selector:@selector(doClick)
                                                    userInfo:nil
                                                     repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    } else {
        [self.timer invalidate]; self.timer = nil;
    }
}

- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint c = self.btn.center;
    self.target = c;
    self.dot.center = c;
    self.coordLabel.text = [NSString stringWithFormat:@"(%.0f, %.0f)", c.x, c.y];
    // Rung phản hồi
    [UIView animateWithDuration:0.1 animations:^{ self.btn.transform = CGAffineTransformMakeScale(1.35,1.35); }
                     completion:^(BOOL f){ [UIView animateWithDuration:0.1 animations:^{ self.btn.transform = CGAffineTransformIdentity; }]; }];
}

- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:g.view.superview];
    CGPoint c = g.view.center;
    c.x += d.x; c.y += d.y;
    g.view.center = c;
    [g setTranslation:CGPointZero inView:g.view.superview];
    self.coordLabel.frame = CGRectMake(c.x + 32, c.y - 11, 110, 22);
}

- (void)doClick {
    flashAt(self.target, self.overlay.rootViewController.view);
    sendFakeTouch(self.target);
}

@end

// ─── Entry Point ──────────────────────────────────────────────────────────────

__attribute__((constructor))
static void acInit(void) {
    NSLog(@"[AutoClicker v3] Loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[ACController shared] setup];
        NSLog(@"[AutoClicker v3] UI ready");
    });
}
