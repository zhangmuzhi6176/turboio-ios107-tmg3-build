#import <Foundation/Foundation.h>
#ifndef TCE_DIAGNOSTIC_TEST
#import <UIKit/UIKit.h>
#else
@class UIImage;
#endif
#import "EditorModel.h"
NSArray<NSString *> *TCEIconNames(void);
NSData *TCEMonochrome(UIImage *image,NSUInteger size,CGFloat threshold,BOOL invert);
UIImage *TCEBitmap(NSData *pixels,NSUInteger size);
NSData *TCEEncode(NSDictionary *draft,NSString **reason);
NSDictionary *TCEInstall(NSDictionary *draft,NSString **reason);
NSDictionary *TCETemplate(NSUInteger index,NSString *identifier);
NSArray<NSString *> *TCETemplateNames(void);
NSDictionary *TCEReorder(NSDictionary *snapshot,NSString *identifier);
BOOL TCEVerifyOrder(NSDictionary *before,NSDictionary *after,NSString *identifier);
BOOL TCESnapshot(id snapshot);
// Metadata only: never returns keys, IDs, names, text, credentials or raw JSON.
// The optional snapshot is the original parsed object, only when the existing
// snapshot rules pass. It is for the internal mutation flow, not for export.
NSDictionary *TCEConfigDiagnostic(id reply,NSString *stage,BOOL mutationSent,BOOL matchedReply,NSDictionary **snapshot);
NSString *TCEConfigDiagnosticSummary(NSDictionary *report);
NSString *TCEConfigDiagnosticReason(NSDictionary *report);
NSString *TCEConfigStage(NSString *stage);
BOOL TCEInspectionAllowsCommand(id command);
