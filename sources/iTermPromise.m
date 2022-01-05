//
//  iTermPromise.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 2/10/20.
//

#import "iTermPromise.h"

#import "NSObject+iTerm.h"

@implementation iTermOr {
    id _first;
    id _second;
}

+ (instancetype)first:(id)object {
    assert(object);
    return [[self alloc] initWithFirst:object second:nil];
}

+ (instancetype)second:(id)object {
    assert(object);
    return [[self alloc] initWithFirst:nil second:object];
}

- (instancetype)initWithFirst:(id)first second:(id)second {
    self = [super init];
    if (self) {
        _first = first;
        _second = second;
    }
    return self;
}

- (void)whenFirst:(void (^ NS_NOESCAPE)(id))firstBlock
           second:(void (^ NS_NOESCAPE)(id))secondBlock {
    if (_first && firstBlock) {
        firstBlock(_first);
    } else if (_second && secondBlock) {
        secondBlock(_second);
    }
}

- (BOOL)hasFirst {
    return _first != nil;
}

- (BOOL)hasSecond {
    return _second != nil;
}

- (NSString *)description {
    __block NSString *value;
    [self whenFirst:^(id  _Nonnull object) {
        value = [NSString stringWithFormat:@"first=%@", object];
    } second:^(id  _Nonnull object) {
        value = [NSString stringWithFormat:@"second=%@", object];
    }];
    return [NSString stringWithFormat:@"<%@: %p %@>", NSStringFromClass(self.class), self, value];
}

- (BOOL)isEqual:(id)object {
    if (object == self) {
        return YES;
    }
    iTermOr *other = [iTermOr castFrom:object];
    if (!other) {
        return NO;
    }
    return [NSObject object:_first isEqualToObject:other->_first] && [NSObject object:_second isEqualToObject:other->_second];
}

- (NSUInteger)hash {
    return [_first hash] | [_second hash];
}

@end

@interface iTermPromiseSeal: NSObject<iTermPromiseSeal>

@property (nonatomic, readonly) iTermOr<id, NSError *> *value;
@property (nonatomic, readonly) void (^observer)(iTermOr<id, NSError *> *value);

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithLock:(NSObject *)lock
                     promise:(id)promise
                    observer:(void (^)(iTermOr<id, NSError *> *))observer
NS_DESIGNATED_INITIALIZER;

- (void)fulfill:(id)value;
- (void)reject:(NSError *)error;

@end

@implementation iTermPromiseSeal {
    NSObject *_lock;
    // The seal keeps the promise from getting dealloced. This gets nilled out after fulfill/reject.
    // This works because the provider must eventually either fulfill or reject and it has to keep
    // the seal around until that happens.
    id _promise;
}

- (instancetype)initWithLock:(NSObject *)lock
                     promise:(id)promise
                    observer:(void (^)(iTermOr<id, NSError *> *))observer {
    self = [super init];
    if (self) {
        _observer = [observer copy];
        _promise = promise;
        _lock = lock;
    }
    return self;
}

- (void)dealloc {
    // This assertion fails if the seal was dealloc'ed without fulfill or reject called.
    assert(_promise == nil);
}

- (void)fulfill:(id)value {
    assert(value);
    @synchronized (_lock) {
        assert(_value == nil);
        _value = [iTermOr first:value];
        self.observer(self.value);
        _promise = nil;
    }
}

- (void)reject:(NSError *)error {
    assert(error);
    @synchronized (_lock) {
        assert(_value == nil);
        _value = [iTermOr second:error];
        self.observer(self.value);
        _promise = nil;
    }
}

@end

typedef void (^iTermPromiseCallback)(iTermOr<id, NSError *> *);

@interface iTermPromise()
@property (nonatomic, strong) iTermOr<id, NSError *> *value;
@property (nonatomic, copy) id<iTermPromiseSeal> seal;
@property (nonatomic, strong) NSMutableArray<iTermPromiseCallback> *callbacks;
@end

@implementation iTermPromise {
    NSObject *_lock;
}

+ (instancetype)promise:(void (^ NS_NOESCAPE)(id<iTermPromiseSeal>))block {
    return [[iTermPromise alloc] initPrivate:block];
}

- (instancetype)initPrivate:(void (^ NS_NOESCAPE)(id<iTermPromiseSeal>))block {
    self = [super init];
    if (self) {
        _callbacks = [NSMutableArray array];
        _lock = [[NSObject alloc] init];
        __weak __typeof(self) weakSelf = self;
        iTermPromiseSeal *seal = [[iTermPromiseSeal alloc] initWithLock:_lock
                                                                promise:self
                                                               observer:^(iTermOr<id,NSError *> *or) {
            [or whenFirst:^(id object) { [weakSelf didFulfill:object]; }
                   second:^(NSError *object) { [weakSelf didReject:object]; }];
        }];
        if (self) {
            block(seal);
        }
    }
    return self;
}

- (BOOL)isEqual:(id)object {
    return self == object;
}

- (NSUInteger)hash {
    NSUInteger result;
    void *selfPtr = (__bridge void *)self;
    assert(sizeof(result) == sizeof(selfPtr));
    memmove(&result, &selfPtr, sizeof(result));
    return result;
}

- (void)didFulfill:(id)object {
    @synchronized (_lock) {
        assert(!self.value);
        self.value = [iTermOr first:object];
    }
}

- (void)didReject:(NSError *)error {
    @synchronized (_lock) {
        assert(!self.value);
        self.value = [iTermOr second:error];
    }
}

- (void)setValue:(iTermOr<id, NSError *> *)value {
    @synchronized (_lock) {
        assert(!_value);
        assert(value);

        _value = value;
        [self notify];
    }
}

- (void)addCallback:(iTermPromiseCallback)callback {
    @synchronized (_lock) {
        assert(callback);
        assert(_callbacks);
        [_callbacks addObject:[callback copy]];

        [self notify];
    }
}

- (void)notify {
    @synchronized (_lock) {
        id value = self.value;
        if (!value) {
            return;
        }
        NSArray<iTermPromiseCallback> *callbacks = [self.callbacks copy];
        [self.callbacks removeAllObjects];
        [callbacks enumerateObjectsUsingBlock:^(iTermPromiseCallback _Nonnull callback, NSUInteger idx, BOOL * _Nonnull stop) {
            callback(value);
        }];
    }
}

- (iTermPromise *)then:(void (^)(id))block {
    @synchronized (_lock) {

        iTermPromise *next = [iTermPromise promise:^(id<iTermPromiseSeal> seal) {
            [self addCallback:^(iTermOr<id,NSError *> *value) {
                // _lock is held at this point since this is called from -notify.
                [value whenFirst:^(id object) {
                    block(object);
                    [seal fulfill:object];
                }
                          second:^(NSError *object) {
                    [seal reject:object];
                }];
            }];
        }];
        return next;
    }
}

- (iTermPromise *)catchError:(void (^)(NSError *error))block {
    @synchronized (_lock) {
        iTermPromise *next = [iTermPromise promise:^(id<iTermPromiseSeal> seal) {
            [self addCallback:^(iTermOr<id,NSError *> *value) {
                // _lock is held at this point since this is called from -notify.
                [value whenFirst:^(id object) {
                    [seal fulfill:object];
                }
                          second:^(NSError *object) {
                    block(object);
                    [seal reject:object];
                }];
            }];
        }];
        return next;
    }
}

- (BOOL)hasValue {
    @synchronized (_lock) {
        return self.value != nil;
    }
}

- (id)maybeValue {
    __block id result = nil;
    @synchronized (_lock) {
        [self.value whenFirst:^(id  _Nonnull object) {
            result = object;
        } second:^(NSError * _Nonnull object) {
            result = nil;
        }];
    }
    return result;
}

@end
