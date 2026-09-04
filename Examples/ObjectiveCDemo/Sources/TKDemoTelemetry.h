#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TKDemoErrorCompletion)(NSError * _Nullable error);

@interface TKDemoTelemetry : NSObject

@property(nonatomic, readonly, getter=isCollectionEnabled) BOOL collectionEnabled;

+ (instancetype)shared;

- (void)setCollectionEnabled:(BOOL)enabled
                  completion:(TKDemoErrorCompletion)completion;

- (void)captureButtonTapWithCompletion:(TKDemoErrorCompletion)completion;

- (void)flushWithCompletion:(TKDemoErrorCompletion)completion;

@end

NS_ASSUME_NONNULL_END
