// AutoClicker.m - v3 (stable, no crash)
// Dùng direct responder chain + try/catch để tránh văng game

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ─── Touch Simulation (safe, no crash) ───────────────────────────────────────

// UIKit's UITouch initializer and phase/location setters are private APIs.
// Build one touch lifecycle with those setters instead of creating a bare UITouch
// and mutating it through KVC (which can leave UIKit's internal state invalid).
@interface UITouch (ACPrivateTouch)
- (void)setWindow:(UIWindow *)window;
- (void)setView:(UIView *)view;
- (void)setTapCount:(NSUInteger)tapCount;
- (void)setIsTap:(BOOL)isTap;
- (void)setTimestamp:(NSTimeInterval)timestamp;
- (void)setPhase:(UITouchPhase)phase;
- (void)setGestureView:(UIView *)view;
- (void)_setLocationInWindow:(CGPoint)location resetPrevious:(BOOL)resetPrevious;
- (void)_setIsFirstTouchForView:(BOOL)firstTouchForView;
- (void)_setIsTapToClick:(BOOL)isTapToClick;
@end

@interface UIEvent (ACPrivateTouches)
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
- (void)_clearTouches;
@end

@interface UIApplication (ACPrivateTouchEvent)
- (UIEvent *)_touchesEvent;
@end

static UITouch *ACCreateTouch(CGPoint point, UIWindow *window) {
    if (!window) return nil;
    UITouch *touch = [[UITouch alloc] init];
    if (!touch) return nil;

    // setWindow: resets UIKit's internal touch fields, so it must be first.
    [touch setWindow:window];
    [touch _setLocationInWindow:point resetPrevious:YES];

    UIView *hitView = [window hitTest:point withEvent:nil] ?: window;
    [touch setView:hitView];
    [touch setGestureView:hitView];
    [touch setTapCount:1];
    [touch setIsTap:NO];
    [touch _setIsFirstTouchForView:YES];
    if ([touch respondsToSelector:@selector(_setIsTapToClick:)]) {
        [touch _setIsTapToClick:NO];
    }
    [touch setTimestamp:NSProcessInfo.processInfo.systemUptime];
    [touch setPhase:UITouchPhaseBegan];
    return touch;
}

static void ACDispatchTouch(UIApplication *app, UITouch *touch) {
    if (![app respondsToSelector:@selector(_touchesEvent)] || !touch) return;

    UIEvent *event = [app _touchesEvent];
    if (!event) return;
    if ([event respondsToSelector:@selector(_clearTouches)]) {
        [event _clearTouches];
    }
    if (![event respondsToSelector:@selector(_addTouch:forDelayedDelivery:)]) return;

    [event _addTouch:touch forDelayedDelivery:NO];
    [app sendEvent:event];
}

static void sendFakeTouch(CGPoint point) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = UIApplication.sharedApplication;
        UIWindow *gameWin = nil;

        for (UIWindow *window in app.windows) {
            if (!window.isHidden &&
                ![NSStringFromClass(window.class) isEqualToString:@"PassthroughWindow"]) {
                gameWin = window;
                break;
            }
        }
        if (!gameWin) gameWin = app.keyWindow;
        if (!gameWin || [NSStringFromClass(gameWin.class) isEqualToString:@"PassthroughWindow"]) {
            NSLog(@"[AutoClicker] No game window available; tap skipped");
            return;
        }

        UITouch *touch = ACCreateTouch(point, gameWin);
        if (!touch) return;
        ACDispatchTouch(app, touch);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            [touch _setLocationInWindow:point resetPrevious:NO];
            [touch setTimestamp:NSProcessInfo.processInfo.systemUptime];
            [touch setPhase:UITouchPhaseEnded];
            ACDispatchTouch(app, touch);
        });
    });
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

    // Kéo chấm đỏ để chọn vị trí tự chạm.
    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0,0,24,24)];
    dot.center = self.target;
    dot.backgroundColor = [UIColor colorWithRed:1 green:0.15 blue:0.15 alpha:0.85];
    dot.layer.cornerRadius = 12;
    dot.layer.borderColor = UIColor.whiteColor.CGColor;
    dot.layer.borderWidth = 1.5;
    dot.userInteractionEnabled = YES;
    UIPanGestureRecognizer *dotPan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(moveTarget:)];
    [dot addGestureRecognizer:dotPan];
    self.dot = dot;
    [root addSubview:dot];

    // Tọa độ đang chọn
    UILabel *lbl = [UILabel new];
    lbl.frame = CGRectMake(self.target.x + 14, self.target.y - 11, 110, 22);
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
        // Click ngay lần đầu, sau đó mỗi 0.5 giây
        [self doClick];
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                      target:self
                                                    selector:@selector(doClick)
                                                    userInfo:nil
                                                     repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    } else {
        [self.timer invalidate]; self.timer = nil;
    }
}

- (void)moveTarget:(UIPanGestureRecognizer *)g {
    CGPoint p = [g locationInView:self.overlay.rootViewController.view];
    CGSize bounds = self.overlay.rootViewController.view.bounds.size;
    CGFloat margin = 12.0;
    p.x = MIN(MAX(p.x, margin), bounds.width - margin);
    p.y = MIN(MAX(p.y, margin), bounds.height - margin);
    self.target = p;
    self.dot.center = p;
    self.coordLabel.frame = CGRectMake(p.x + 16, p.y - 11, 110, 22);
    self.coordLabel.text = [NSString stringWithFormat:@"(%.0f, %.0f)", p.x, p.y];
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
