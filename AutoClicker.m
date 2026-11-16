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
    [touch setTapCount:1];

    // KIF uses different internal touch flags before and after iOS 14.
    // iOS 15–16 follows the newer path; older flags can throw an
    // unrecognized-selector exception and abort the host game.
    if (@available(iOS 14.0, *)) {
        if ([touch respondsToSelector:@selector(_setIsTapToClick:)]) {
            [touch _setIsTapToClick:NO];
        }
    } else {
        if ([touch respondsToSelector:@selector(_setIsFirstTouchForView:)]) {
            [touch _setIsFirstTouchForView:YES];
        }
        if ([touch respondsToSelector:@selector(setIsTap:)]) {
            [touch setIsTap:NO];
        }
    }

    if ([touch respondsToSelector:@selector(setGestureView:)]) {
        [touch setGestureView:hitView];
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
@property (nonatomic) BOOL isRunning;
@property (nonatomic) NSUInteger nextTargetIndex;
@property (nonatomic, strong) NSMutableArray<NSValue *> *targets;
@property (nonatomic, strong) NSMutableArray<UIView *> *dots;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) UIWindow *overlay;
@property (nonatomic, strong) UIView *rootView;
@property (nonatomic, strong) UIButton *btn;
@property (nonatomic, strong) UILabel *coordLabel;
+ (instancetype)shared;
- (void)setup;
- (void)addTarget;
- (void)removeTarget;
- (void)moveTarget:(UIPanGestureRecognizer *)g;
- (void)doClick;
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
        _targets = [NSMutableArray array];
        _dots = [NSMutableArray array];
        _nextTargetIndex = 0;
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
    self.rootView = root;

    // Nút chạy/dừng.
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(10, 140, 54, 54);
    [self applyStyle:b on:NO];
    [b addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    self.btn = b;
    [root addSubview:b];

    // Thêm/bớt điểm ở cạnh nút chạy.
    UIButton *plus = [self smallButtonWithTitle:@"+" frame:CGRectMake(72, 149, 40, 36)];
    [plus addTarget:self action:@selector(addTarget) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:plus];

    UIButton *minus = [self smallButtonWithTitle:@"−" frame:CGRectMake(118, 149, 40, 36)];
    [minus addTarget:self action:@selector(removeTarget) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:minus];

    UILabel *lbl = [UILabel new];
    lbl.frame = CGRectMake(10, 202, 132, 22);
    lbl.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    lbl.textColor = UIColor.whiteColor;
    lbl.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    lbl.layer.cornerRadius = 4;
    lbl.clipsToBounds = YES;
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.userInteractionEnabled = NO;
    self.coordLabel = lbl;
    [root addSubview:lbl];

    // Tạo điểm chạm đầu tiên.
    [self addTarget];
}

- (UIButton *)smallButtonWithTitle:(NSString *)title frame:(CGRect)frame {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = frame;
    button.layer.cornerRadius = 8;
    button.layer.borderWidth = 1;
    button.layer.borderColor = UIColor.whiteColor.CGColor;
    button.backgroundColor = [UIColor colorWithRed:0.1 green:0.5 blue:1.0 alpha:0.9];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    return button;
}

- (void)addTarget {
    if (self.targets.count >= 8 || !self.rootView) return;

    NSUInteger index = self.targets.count;
    CGSize size = self.rootView.bounds.size;
    CGFloat column = (CGFloat)(index % 3);
    CGFloat row = (CGFloat)(index / 3);
    CGPoint point = CGPointMake(size.width * 0.5 + (column - 1.0) * 54.0,
                                size.height * 0.78 - row * 64.0);

    UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 28, 28)];
    dot.center = point;
    dot.backgroundColor = [UIColor colorWithRed:1 green:0.15 blue:0.15 alpha:0.9];
    dot.layer.cornerRadius = 14;
    dot.layer.borderColor = UIColor.whiteColor.CGColor;
    dot.layer.borderWidth = 1.5;
    dot.userInteractionEnabled = YES;
    dot.tag = 1000 + index;

    UILabel *number = [[UILabel alloc] initWithFrame:dot.bounds];
    number.tag = 1;
    number.text = [NSString stringWithFormat:@"%lu", (unsigned long)index + 1];
    number.font = [UIFont boldSystemFontOfSize:12];
    number.textColor = UIColor.whiteColor;
    number.textAlignment = NSTextAlignmentCenter;
    number.userInteractionEnabled = NO;
    [dot addSubview:number];

    UIPanGestureRecognizer *drag = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(moveTarget:)];
    [dot addGestureRecognizer:drag];

    [self.targets addObject:[NSValue valueWithCGPoint:point]];
    [self.dots addObject:dot];
    [self.rootView addSubview:dot];
    [self updateCoordinateLabelForPoint:point index:index];
}

- (void)removeTarget {
    // Keep at least one point so the start button always has a target.
    if (self.targets.count <= 1) return;

    UIView *dot = self.dots.lastObject;
    [dot removeFromSuperview];
    [self.dots removeLastObject];
    [self.targets removeLastObject];
    self.nextTargetIndex = self.nextTargetIndex % self.targets.count;

    [self.dots enumerateObjectsUsingBlock:^(UIView *marker, NSUInteger idx, BOOL *stop) {
        marker.tag = 1000 + idx;
        UILabel *number = (UILabel *)[marker viewWithTag:1];
        number.text = [NSString stringWithFormat:@"%lu", (unsigned long)idx + 1];
    }];

    CGPoint point = self.targets.lastObject.CGPointValue;
    [self updateCoordinateLabelForPoint:point index:self.targets.count - 1];
}

- (void)updateCoordinateLabelForPoint:(CGPoint)point index:(NSUInteger)index {
    self.coordLabel.text = [NSString stringWithFormat:@"%lu: (%.0f, %.0f)",
                            (unsigned long)index + 1, point.x, point.y];
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
        self.nextTargetIndex = 0;
        [self doClick];
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                      target:self
                                                    selector:@selector(doClick)
                                                    userInfo:nil
                                                     repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    } else {
        [self.timer invalidate];
        self.timer = nil;
    }
}

- (void)moveTarget:(UIPanGestureRecognizer *)g {
    NSUInteger index = g.view.tag - 1000;
    if (index >= self.targets.count) return;

    CGPoint point = [g locationInView:self.rootView];
    CGSize bounds = self.rootView.bounds.size;
    CGFloat margin = 14.0;
    point.x = MIN(MAX(point.x, margin), bounds.width - margin);
    point.y = MIN(MAX(point.y, margin), bounds.height - margin);

    self.targets[index] = [NSValue valueWithCGPoint:point];
    g.view.center = point;
    [self updateCoordinateLabelForPoint:point index:index];
}

- (void)doClick {
    if (self.targets.count == 0) return;

    NSUInteger index = self.nextTargetIndex % self.targets.count;
    CGPoint point = self.targets[index].CGPointValue;
    flashAt(point, self.rootView);
    sendFakeTouch(point);
    self.nextTargetIndex = (index + 1) % self.targets.count;
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
