//
//  NSResponder+iTerm.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 1/10/18.
//

#import "NSResponder+iTerm.h"

#import "DebugLogging.h"
#import "NSObject+iTerm.h"

#import <objc/runtime.h>

static char iTermIgnoreFirstResponderChangesCountKey;

@implementation NSResponder (iTerm)

- (BOOL)it_shouldIgnoreFirstResponderChanges {
    NSNumber *count = objc_getAssociatedObject(self, &iTermIgnoreFirstResponderChangesCountKey);
    return count.intValue > 0;
}

- (void)it_ignoreFirstResponderChangesInBlock:(void (^)(void))block {
    NSNumber *count = objc_getAssociatedObject(self, &iTermIgnoreFirstResponderChangesCountKey);
    NSNumber *newCount = @(count.intValue + 1);
    objc_setAssociatedObject(self,
                             &iTermIgnoreFirstResponderChangesCountKey,
                             newCount,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    DLog(@"incr: count of %@ becomes %@.", self, newCount);
    block();
    DLog(@"decr: count of %@ becomes %@.", self, count);
    objc_setAssociatedObject(self,
                             &iTermIgnoreFirstResponderChangesCountKey,
                             count.intValue ? count : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (BOOL)it_wantsScrollWheelMomentumEvents {
    return NO;
}

- (void)it_scrollWheelMomentum:(NSEvent *)event {
}

- (BOOL)it_preferredFirstResponder {
    NSTextView *textView = [NSTextView castFrom:self];
    if (textView) {
        id delegate = [textView delegate];
        if ([delegate respondsToSelector:_cmd]) {
            return [(NSResponder *)delegate it_preferredFirstResponder];
        }
    }
    return NO;
}

- (BOOL)it_isTerminalResponder {
    return NO;
}

@end
