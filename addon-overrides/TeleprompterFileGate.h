#import <Foundation/Foundation.h>

// A bounded exception to the OTA sendFile interlock. No sending, path rewriting,
// file mutation or raw diagnostic export is performed here.
@interface TIOTeleprompterFileGate : NSObject
- (instancetype)initWithContainer:(NSString *)container;
- (void)observeMethod:(NSString *)method arguments:(NSDictionary *)arguments otaStage:(NSUInteger)stage uptime:(NSTimeInterval)now;
- (void)observeEvent:(NSDictionary *)event uptime:(NSTimeInterval)now;
- (BOOL)allowsMethod:(NSString *)method arguments:(NSDictionary *)arguments otaStage:(NSUInteger)stage uptime:(NSTimeInterval)now;
- (void)invalidate;
// Only a fixed build marker, fixed reason and an armed boolean. No IDs/paths/text.
- (NSDictionary *)diagnostic;
@end
