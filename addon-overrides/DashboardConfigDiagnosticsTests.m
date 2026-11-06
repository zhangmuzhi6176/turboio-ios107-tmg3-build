#import <Foundation/Foundation.h>
#import "EditorCodec.h"
#include <assert.h>
#include <stdio.h>

static NSString *const SecretID=@"PRIVATE_CARD_ID_4f834d";
static NSString *const SecretText=@"PRIVATE_TODO_TEXT_appointment_731";
static NSString *const SecretKey=@"PRIVATE_ACCOUNT_KEY_80fa";
static NSDictionary *Reply(id data){return @{@"cmd":@"dashboard_config",@"payload":@{@"data":data?:NSNull.null}};}
static void Private(NSDictionary *report){
 NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];assert(json);
 NSString *serialized=[[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding];
 NSString *summary=TCEConfigDiagnosticSummary(report);
 for(NSString *secret in @[SecretID,SecretText,SecretKey,@"PRIVATE_USER_STAGE",@"PRIVATE_COMMAND"]){
  assert([serialized rangeOfString:secret].location==NSNotFound);
  assert([summary rangeOfString:secret].location==NSNotFound);
 }
 assert([summary containsString:@"DASH-CONFIG-DIAG01"]);
}
static NSDictionary *Diagnose(id snapshot){
 NSDictionary *parsed=nil;NSDictionary *report=TCEConfigDiagnostic(Reply(snapshot),@"读取配置诊断",NO,YES,&parsed);
 Private(report);assert([report[@"valid"]boolValue]==TCESnapshot(snapshot));
 assert((parsed!=nil)==[report[@"valid"]boolValue]);return report;
}
static void Bad(id snapshot,NSString *reason,NSInteger index){
 NSDictionary *r=Diagnose(snapshot);assert(![r[@"valid"]boolValue]);assert([r[@"reason"]isEqual:reason]);assert([r[@"firstInvalidRowIndex"]integerValue]==index);
}
int main(void){@autoreleasepool{
 // The production inspect-session guard admits exactly one fixed read query.
 NSDictionary *query=@{@"cmd":@"dashboard_config",@"payload":@{@"version":@1,@"value":@0}};
 assert(TCEInspectionAllowsCommand(query));assert(!TCEInspectionAllowsCommand(nil));
 for(NSString *cmd in @[@"widget_install",@"widget_uninstall",@"dashboard_update"]){NSMutableDictionary *mutation=[query mutableCopy];mutation[@"cmd"]=cmd;assert(!TCEInspectionAllowsCommand(mutation));}
 NSMutableDictionary *extra=[query mutableCopy];extra[@"private"]=SecretText;assert(!TCEInspectionAllowsCommand(extra));
 NSDictionary *a=@{@"id":SecretID,@"type":@"native",@"name":SecretText,@"extras":@{@"key":SecretKey}};
 NSDictionary *b=@{@"id":@"other_private_card",@"type":@"future_component",@"name":@"keep entire object"};
 NSDictionary *snapshot=@{@"widgets_v2":@[a,b],@"widgets":@[@1,@3],@"simple_mode":@0,SecretKey:SecretText};
 NSDictionary *good=Diagnose(snapshot);assert([good[@"valid"]boolValue]);assert([good[@"widgetsV2Count"]isEqual:@2]);assert([good[@"unknownRootKeyCount"]isEqual:@1]);
 assert([good[@"hasWidgets"]isEqual:@YES]);assert([good[@"widgetsType"]isEqual:@"array"]);assert([good[@"simpleModeType"]isEqual:@"number"]);
 assert([Diagnose(@{@"widgets_v2":@[]})[@"valid"]boolValue]);
 // The existing rule requires type to be a string; it never required a value whitelist.
 assert([Diagnose(@{@"widgets_v2":@[@{@"id":SecretID,@"type":@""}]})[@"valid"]boolValue]);
 Bad(@[],@"snapshot_not_object",-1);Bad(NSNull.null,@"snapshot_not_object",-1);
 Bad(@{@"widgets":@[@1]},@"widgets_v2_missing",-1);
 Bad(@{@"widgets_v2":NSNull.null},@"widgets_v2_not_array",-1);
 Bad(@{@"widgets_v2":SecretText},@"widgets_v2_not_array",-1);
 NSMutableArray *large=[NSMutableArray new];for(NSUInteger i=0;i<33;i++)[large addObject:a];Bad(@{@"widgets_v2":large},@"row_limit_exceeded",-1);
 Bad(@{@"widgets_v2":@[a,SecretText]},@"row_not_object",1);
 Bad(@{@"widgets_v2":@[@{@"type":@"native"}]},@"id_not_string",0);
 Bad(@{@"widgets_v2":@[@{@"id":@7,@"type":@"native"}]},@"id_not_string",0);
 Bad(@{@"widgets_v2":@[@{@"id":@"",@"type":@"native"}]},@"id_empty",0);
 Bad(@{@"widgets_v2":@[@{@"id":SecretID,@"type":@7}]},@"type_not_string",0);
 NSDictionary *duplicate=Diagnose(@{@"widgets_v2":@[a,b,a]});assert([duplicate[@"reason"]isEqual:@"duplicate_id"]);assert([duplicate[@"firstInvalidRowIndex"]isEqual:@2]);assert([duplicate[@"duplicateFirstRowIndex"]isEqual:@0]);assert([duplicate[@"duplicateRowIndex"]isEqual:@2]);
 assert([TCEConfigDiagnosticSummary(duplicate)containsString:@"第 1 项与第 3 项"]);
 NSData *bytes=[NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];NSString *string=[[NSString alloc]initWithData:bytes encoding:NSUTF8StringEncoding];
 NSDictionary *parsed=nil;NSDictionary *json=TCEConfigDiagnostic(Reply(string),@"读取安装结果",YES,YES,&parsed);Private(json);assert([json[@"jsonParse"]isEqual:@"ok"]);assert([json[@"valid"]boolValue]);assert([parsed isEqual:snapshot]);assert([json[@"stage"]isEqual:@"after_install"]);assert([json[@"mutationSent"]isEqual:@YES]);
 NSDictionary *badJSON=TCEConfigDiagnostic(Reply([NSString stringWithFormat:@"{\"%@\":\"%@\",",SecretKey,SecretText]),@"读取配置诊断",NO,YES,&parsed);Private(badJSON);assert(!parsed);assert([badJSON[@"reason"]isEqual:@"json_parse_failed"]);assert([badJSON[@"jsonParse"]isEqual:@"error"]);
 for(id reply in @[@{},@{@"cmd":@"dashboard_config"},@{@"cmd":@"dashboard_config",@"payload":SecretText},@{@"cmd":@"dashboard_config",@"payload":@{SecretKey:SecretText}},@{@"cmd":@"PRIVATE_COMMAND",@"payload":@{@"data":snapshot}}]){
  NSDictionary *r=TCEConfigDiagnostic(reply,@"PRIVATE_USER_STAGE",NO,YES,&parsed);Private(r);assert(!parsed);assert(![r[@"valid"]boolValue]);assert([r[@"stage"]isEqual:@"unknown"]);
 }
 NSDictionary *unmatched=TCEConfigDiagnostic(Reply(snapshot),@"读取原顺序",NO,NO,&parsed);Private(unmatched);assert(!parsed);assert([unmatched[@"reason"]isEqual:@"no_matched_reply"]);assert(![unmatched[@"valid"]boolValue]);
 // Summary formatting also treats a tampered/stale report as untrusted input.
 NSMutableDictionary *tampered=[good mutableCopy];for(NSString *field in @[@"stage",@"reason",@"replyType",@"payloadType",@"dataType",@"snapshotType",@"widgetsV2Type",@"widgetsType",@"simpleModeType",@"jsonParse"]){tampered[field]=SecretText;}
 assert(![TCEConfigDiagnosticSummary(tampered)containsString:SecretText]);
 // Publishing still requires the entire other-card contents and order to remain identical.
 NSDictionary *own=@{@"id":@"turbo_ui_card_safe_test",@"type":@"a2ui"};
 NSMutableDictionary *after=[snapshot mutableCopy];after[@"widgets_v2"]=@[own,a,b];assert(TCEVerifyOrder(snapshot,after,own[@"id"]));
 after[@"widgets_v2"]=@[own,b,a];assert(!TCEVerifyOrder(snapshot,after,own[@"id"]));
 NSMutableDictionary *changed=[a mutableCopy];changed[@"name"]=@"changed";after[@"widgets_v2"]=@[own,changed,b];assert(!TCEVerifyOrder(snapshot,after,own[@"id"]));
 after[@"widgets_v2"]=@[own,a];assert(!TCEVerifyOrder(snapshot,after,own[@"id"]));
 after[@"widgets_v2"]=@[own,a,b];after[@"simple_mode"]=@1;assert(!TCEVerifyOrder(snapshot,after,own[@"id"]));
 printf("dashboard configuration diagnostics: PASS\n");
}return 0;}
