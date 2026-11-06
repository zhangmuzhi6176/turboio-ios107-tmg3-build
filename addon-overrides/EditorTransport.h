#import <Foundation/Foundation.h>
BOOL TCEBusy(void);
NSString *TCEStatus(void);
// One dashboard_config query only. Never installs, removes or reorders cards.
void TCEInspect(void);
// Plain, redacted metadata for explicit copy/share actions.
NSString *TCEDiagnosticSummary(void);
void TCEPublish(NSDictionary *draft,BOOL first);
// UI thread only. Explicit local approval precedes this call. The callback
// reports config readback, never physical rendering. Busy/peer mismatch -> NO.
BOOL TCEPublishWithCompletion(NSDictionary *draft,NSString *expectedPeer,void(^complete)(NSDictionary *receipt));
void TCERemove(NSString *identifier);
void TCEObserveEvent(NSDictionary *event);
