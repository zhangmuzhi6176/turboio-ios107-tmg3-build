#import "EditorCodec.h"
#ifndef TCE_DIAGNOSTIC_TEST
#import "A2UIProbe.h"
#import "DashboardCard.h"
#include "editor.h"
#include <math.h>
NSArray *TCEIconNames(void){return @[@"sparkles",@"sun.max",@"laptopcomputer",@"cpu",@"memorychip",@"internaldrive",@"battery.75percent",@"cloud",@"book",@"music.note",@"location",@"timer",@"heart",@"checkmark.circle",@"chart.line.uptrend.xyaxis",@"bell"];}
NSData *TCEMonochrome(UIImage *image,NSUInteger size,CGFloat threshold,BOOL invert){
 if(!image||![@[@16,@24,@32,@48]containsObject:@(size)]||!isfinite(threshold)||threshold<0||threshold>1)return nil;
 UIGraphicsImageRendererFormat *f=[UIGraphicsImageRendererFormat defaultFormat];f.scale=1;f.opaque=YES;
 UIImage *scaled=[[[UIGraphicsImageRenderer alloc]initWithSize:CGSizeMake(size,size) format:f]imageWithActions:^(UIGraphicsImageRendererContext *r){[UIColor.blackColor setFill];UIRectFill(CGRectMake(0,0,size,size));[image drawInRect:CGRectMake(0,0,size,size)];}];
 NSMutableData *gray=[NSMutableData dataWithLength:size*size];CGColorSpaceRef space=CGColorSpaceCreateDeviceGray();CGContextRef c=CGBitmapContextCreate(gray.mutableBytes,size,size,8,size,space,(CGBitmapInfo)kCGImageAlphaNone);CGColorSpaceRelease(space);if(!c)return nil;
 CGContextDrawImage(c,CGRectMake(0,0,size,size),scaled.CGImage);CGContextRelease(c);NSMutableData *out=[NSMutableData dataWithLength:size*size/8];const uint8_t *p=gray.bytes;uint8_t *bits=out.mutableBytes;
 for(NSUInteger i=0;i<size*size;i++)if((p[i]>=threshold*255)!=invert)bits[i/8]|=0x80>>(i%8);return out;
}
UIImage *TCEBitmap(NSData *pixels,NSUInteger size){
 if(![@[@16,@24,@32,@48]containsObject:@(size)]||pixels.length!=size*size/8)return nil;NSMutableData *rgba=[NSMutableData dataWithLength:size*size*4];uint8_t *p=rgba.mutableBytes;const uint8_t *b=pixels.bytes;
 for(NSUInteger i=0;i<size*size;i++){p[i*4+1]=(b[i/8]&(0x80>>(i%8)))?255:0;p[i*4+3]=255;}
 CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);CGColorSpaceRef s=CGColorSpaceCreateDeviceRGB();CGImageRef cg=CGImageCreate(size,size,8,32,size*4,s,kCGImageAlphaLast|kCGBitmapByteOrderDefault,provider,NULL,false,kCGRenderingIntentDefault);UIImage *image=cg?[UIImage imageWithCGImage:cg]:nil;if(cg)CGImageRelease(cg);CGColorSpaceRelease(s);CGDataProviderRelease(provider);return image;
}
static NSData *Icon(NSUInteger index,NSUInteger size){
 if(index>=TCEIconNames().count)return nil;UIImage *i=[UIImage systemImageNamed:TCEIconNames()[index] withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:size-4 weight:UIImageSymbolWeightMedium]];i=[i imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];return TCEMonochrome(i,size,.32,NO);
}
NSData *TCEEncode(NSDictionary *draft,NSString **reason){
 if(!TCEValidateDraft(draft,reason))return nil;NSArray *items=draft[@"components"];uint8_t header[8]={'T','C','E','1',(uint8_t)items.count,0,0,0};NSMutableData *d=[NSMutableData dataWithBytes:header length:8];
 for(NSDictionary *c in items){NSString *k=c[@"kind"];uint8_t type=0,a=0,b=0;NSData *body=[NSData data];
  if([k isEqual:@"text"]){type=TCE_TEXT;a=[c[@"font"]intValue];b=(uint8_t)[@[@"left",@"center",@"right"]indexOfObject:c[@"align"]];body=[c[@"text"]dataUsingEncoding:NSUTF8StringEncoding];}
  else if([k isEqual:@"icon"]||[k isEqual:@"image"]){type=TCE_IMAGE;body=[k isEqual:@"icon"]?Icon([c[@"icon"]unsignedIntegerValue],[c[@"w"]unsignedIntegerValue]):[[NSData alloc]initWithBase64EncodedString:c[@"pixels"] options:0];if(!body){if(reason)*reason=@"图标无法生成";return nil;}}
  else if([k isEqual:@"progress"]){type=TCE_PROGRESS;a=[c[@"value"]intValue];}
  else if([k isEqual:@"barChart"]||[k isEqual:@"lineChart"]){type=[k isEqual:@"barChart"]?TCE_BAR:TCE_LINE;NSMutableData *points=[NSMutableData new];for(NSNumber *v in c[@"points"]){uint8_t p=v.unsignedCharValue;[points appendBytes:&p length:1];}body=points;}
  else type=[k isEqual:@"divider"]?TCE_DIVIDER:TCE_FRAME;
  uint8_t row[10]={type,[c[@"x"]intValue],[c[@"y"]intValue],[c[@"w"]intValue],[c[@"h"]intValue],a,b,0,(uint8_t)body.length,(uint8_t)(body.length>>8)};[d appendBytes:row length:10];[d appendData:body];
 }
 if(d.length>TCE_MAX_BYTES){if(reason)*reason=@"组件编码超过 2048 字节";return nil;}uint8_t *bytes=d.mutableBytes;bytes[6]=d.length&255;bytes[7]=d.length>>8;TCEDocument parsed;if(!tce_decode(d.bytes,d.length,&parsed)){if(reason)*reason=@"固件侧规则不接受此布局";return nil;}return d;
}
NSDictionary *TCEInstall(NSDictionary *draft,NSString **reason){
 NSData *encoded=TCEEncode(draft,reason);if(!encoded)return nil;NSString *id_=draft[@"id"],*name=draft[@"name"],*text=[@"TCE1:" stringByAppendingString:[encoded base64EncodedStringWithOptions:0]];
 NSDictionary *extra=@{@"widgetId":id_,@"name":name,@"uiContent":@{@"createSurface":@{@"surfaceId":id_,@"catalogId":@"https://rayneo.com/a2ui/catalogs/glasses-base/v1/catalog.json"},@"updateComponents":@{@"surfaceId":id_,@"components":@[@{@"id":@"root",@"component":@"Text",@"text":text,@"variant":@"caption"}]}}};
 NSString *json=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:extra options:NSJSONWritingSortedKeys error:nil] encoding:NSUTF8StringEncoding];NSDictionary *install=@{@"cmd":@"widget_install",@"payload":@{@"data":@{@"type":@"a2ui",@"id":id_,@"name":name,@"extras":json}}};if(!TDCRequest(1,install)){if(reason)*reason=@"封装后的蓝牙数据包超过限制";return nil;}return install;
}
#endif
static NSString *Shape(id v){
 if(!v)return @"missing";if(v==NSNull.null)return @"null";
 if([v isKindOfClass:NSDictionary.class])return @"object";
 if([v isKindOfClass:NSArray.class])return @"array";
 if([v isKindOfClass:NSString.class])return @"string";
 if([v isKindOfClass:NSNumber.class])return CFGetTypeID((__bridge CFTypeRef)v)==CFBooleanGetTypeID()?@"boolean":@"number";
 return @"other";
}
NSString *TCEConfigStage(NSString *stage){
 // Only application-owned constants may reach exported diagnostics.
 NSDictionary *names=@{@"读取配置诊断":@"inspect",@"读取原顺序":@"before_install",@"读取删除前状态":@"before_remove",@"读取安装结果":@"after_install",@"读取最终顺序":@"after_reorder",@"读取删除结果":@"after_remove",@"提交卡片":@"install",@"置顶卡片":@"reorder",@"移除卡片":@"remove"};
 return [stage isKindOfClass:NSString.class]?(names[stage]?:@"unknown"):@"unknown";
}
BOOL TCEInspectionAllowsCommand(id command){return [command isKindOfClass:NSDictionary.class]&&[command isEqual:@{@"cmd":@"dashboard_config",@"payload":@{@"version":@1,@"value":@0}}];}
static NSDictionary *SnapshotShape(id s){
 BOOL object=[s isKindOfClass:NSDictionary.class];id raw=object?s[@"widgets_v2"]:nil;
 NSMutableDictionary *d=[@{@"snapshotType":Shape(s),@"hasWidgetsV2":@(raw!=nil),@"widgetsV2Type":Shape(raw),@"widgetsV2Count":@(-1),@"unknownRootKeyCount":@0,@"firstInvalidRowIndex":@(-1),@"duplicateFirstRowIndex":@(-1),@"duplicateRowIndex":@(-1),@"valid":@NO}mutableCopy];
 id widgets=object?s[@"widgets"]:nil,simple=object?s[@"simple_mode"]:nil;
 [d addEntriesFromDictionary:@{@"hasWidgets":@(widgets!=nil),@"widgetsType":Shape(widgets),@"hasSimpleMode":@(simple!=nil),@"simpleModeType":Shape(simple)}];
 if(object){NSUInteger unknown=0;for(id key in s)if(![@[@"widgets_v2",@"widgets",@"simple_mode"]containsObject:key])unknown++;d[@"unknownRootKeyCount"]=@(unknown);}
 NSString *reason=nil;
 if(!object)reason=@"snapshot_not_object";
 else if(!raw)reason=@"widgets_v2_missing";
 else if(![raw isKindOfClass:NSArray.class])reason=@"widgets_v2_not_array";
 else{
  NSArray *rows=raw;d[@"widgetsV2Count"]=@(rows.count);
  if(rows.count>32)reason=@"row_limit_exceeded";
  else{NSMutableDictionary *seen=[NSMutableDictionary new];
   for(NSUInteger i=0;i<rows.count;i++){id row=rows[i];
    if(![row isKindOfClass:NSDictionary.class])reason=@"row_not_object";
    else if(![row[@"id"]isKindOfClass:NSString.class])reason=@"id_not_string";
    else if(![row[@"id"]length])reason=@"id_empty";
    else if(![row[@"type"]isKindOfClass:NSString.class])reason=@"type_not_string";
    else if(seen[row[@"id"]]){reason=@"duplicate_id";d[@"duplicateFirstRowIndex"]=seen[row[@"id"]];d[@"duplicateRowIndex"]=@(i);}
    else seen[row[@"id"]]=@(i);
    if(reason){d[@"firstInvalidRowIndex"]=@(i);d[@"firstInvalidRowType"]=Shape(row);if([row isKindOfClass:NSDictionary.class]){d[@"firstInvalidIdType"]=Shape(row[@"id"]);d[@"firstInvalidTypeType"]=Shape(row[@"type"]);}break;}
   }
  }
 }
 d[@"reason"]=reason?:@"valid";d[@"valid"]=@(!reason);return d;
}
static NSArray *Rows(id s){return [SnapshotShape(s)[@"valid"]boolValue]?s[@"widgets_v2"]:nil;}
BOOL TCESnapshot(id s){return Rows(s)!=nil;}
NSDictionary *TCEConfigDiagnostic(id reply,NSString *stage,BOOL mutationSent,BOOL matchedReply,NSDictionary **snapshot){
 if(snapshot)*snapshot=nil;
 BOOL object=[reply isKindOfClass:NSDictionary.class];id payload=object?reply[@"payload"]:nil;
 BOOL payloadObject=[payload isKindOfClass:NSDictionary.class];id raw=payloadObject?payload[@"data"]:nil;
 id parsed=raw;NSString *parse=@"not_needed";NSNumber *parseCode=@0;
 if([raw isKindOfClass:NSString.class]){NSError *error=nil;NSData *bytes=[raw dataUsingEncoding:NSUTF8StringEncoding];parsed=bytes?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:&error]:nil;parse=parsed?@"ok":@"error";parseCode=error?@(error.code):@0;}
 NSMutableDictionary *d=[SnapshotShape(parsed)mutableCopy];
 id command=object?reply[@"cmd"]:nil;BOOL expectedCommand=[command isEqual:@"dashboard_config"];
 [d addEntriesFromDictionary:@{@"build":@"DASH-CONFIG-DIAG01",@"schemaVersion":@1,@"stage":TCEConfigStage(stage),@"matchedReply":@(matchedReply),@"mutationSent":@(mutationSent),@"replyType":Shape(reply),@"commandType":Shape(command),@"expectedCommand":@(expectedCommand),@"hasPayload":@(payload!=nil),@"payloadType":Shape(payload),@"hasData":@(raw!=nil),@"dataType":Shape(raw),@"jsonParse":parse,@"jsonErrorCode":parseCode}];
 if([parse isEqual:@"error"])d[@"reason"]=@"json_parse_failed";
 if(!expectedCommand){d[@"valid"]=@NO;d[@"reason"]=@"unexpected_command";}
 if(!matchedReply){d[@"valid"]=@NO;d[@"reason"]=@"no_matched_reply";}
 if(snapshot&&[d[@"valid"]boolValue])*snapshot=parsed;
 return d;
}
static NSString *StageLabel(id stage){
 NSDictionary *m=@{@"inspect":@"只读检查",@"before_install":@"读取原顺序（修改前）",@"before_remove":@"读取删除前状态（修改前）",@"after_install":@"读取安装结果（提交后）",@"after_reorder":@"读取最终顺序（排序后）",@"after_remove":@"读取删除结果（删除后）",@"install":@"提交卡片",@"reorder":@"置顶卡片",@"remove":@"移除卡片"};
 return [stage isKindOfClass:NSString.class]?(m[stage]?:@"未知阶段"):@"未知阶段";
}
static NSString *SafeShape(id value){return [@[@"missing",@"null",@"object",@"array",@"string",@"boolean",@"number",@"other"]containsObject:value?:NSNull.null]?value:@"other";}
static NSInteger SafeIndex(id n){return [n isKindOfClass:NSNumber.class]&&[n integerValue]>=0&&[n integerValue]<=1000000?[n integerValue]:-1;}
NSString *TCEConfigDiagnosticReason(NSDictionary *d){
 if(![d isKindOfClass:NSDictionary.class])return @"暂无结构诊断";
 NSDictionary *m=@{@"valid":@"配置结构通过",@"no_matched_reply":@"尚未收到匹配回包",@"unexpected_command":@"回包命令不是 dashboard_config",@"json_parse_failed":@"data 字符串无法解析为 JSON",@"snapshot_not_object":@"配置根不是对象",@"widgets_v2_missing":@"配置缺少 widgets_v2",@"widgets_v2_not_array":@"widgets_v2 不是数组",@"row_limit_exceeded":@"卡片数超过 32",@"row_not_object":@"卡片项不是对象",@"id_not_string":@"卡片 id 不是字符串",@"id_empty":@"卡片 id 为空",@"type_not_string":@"卡片 type 不是字符串",@"duplicate_id":@"卡片 id 重复"};
 id reason=d[@"reason"];NSString *text=[reason isKindOfClass:NSString.class]?(m[reason]?:@"未知结构原因"):@"未知结构原因";
 NSInteger at=SafeIndex(d[@"firstInvalidRowIndex"]);return at>=0?[NSString stringWithFormat:@"第 %ld 项：%@",(long)at+1,text]:text;
}
NSString *TCEConfigDiagnosticSummary(NSDictionary *d){
 if(![d isKindOfClass:NSDictionary.class])return @"DASH-CONFIG-DIAG01\n暂无结构摘要。请点“只读检查仪表盘配置”。";
 NSString *parse=[d[@"jsonParse"]isEqual:@"ok"]?@"成功":[d[@"jsonParse"]isEqual:@"error"]?@"失败":@"无需解析";
 NSInteger count=SafeIndex(d[@"widgetsV2Count"]),unknown=SafeIndex(d[@"unknownRootKeyCount"]),first=SafeIndex(d[@"duplicateFirstRowIndex"]),duplicate=SafeIndex(d[@"duplicateRowIndex"]);
 NSString *items=count>=0?[NSString stringWithFormat:@"%ld",(long)count]:@"不可计数";
 NSMutableString *s=[NSMutableString stringWithFormat:@"DASH-CONFIG-DIAG01\n阶段：%@\n匹配回包：%@ · 本轮已提交修改：%@\n回包 / payload / data：%@ / %@ / %@\nJSON解析：%@\n配置根：%@ · 未列名字段数：%ld\nwidgets_v2：%@ · %@ · 项数 %@\n结果：%@",StageLabel(d[@"stage"]),[d[@"matchedReply"]isEqual:@YES]?@"是":@"否",[d[@"mutationSent"]isEqual:@YES]?@"是":@"否",SafeShape(d[@"replyType"]),SafeShape(d[@"payloadType"]),SafeShape(d[@"dataType"]),parse,SafeShape(d[@"snapshotType"]),(long)MAX(0,unknown),[d[@"hasWidgetsV2"]isEqual:@YES]?@"存在":@"缺失",SafeShape(d[@"widgetsV2Type"]),items,TCEConfigDiagnosticReason(d)];
 if(first>=0&&duplicate>=0)[s appendFormat:@"\n重复位置：第 %ld 项与第 %ld 项",(long)first+1,(long)duplicate+1];
 [s appendFormat:@"\n其他已知字段：widgets=%@，simple_mode=%@",SafeShape(d[@"widgetsType"]),SafeShape(d[@"simpleModeType"])];
 [s appendString:@"\n摘要仅含类型、数量和位置；不包含卡片内容或任何 ID 值。"];return s;
}
#ifndef TCE_DIAGNOSTIC_TEST
NSDictionary *TCEReorder(NSDictionary *s,NSString *ident){NSArray *rows=Rows(s);if(!rows||![ident hasPrefix:@"turbo_ui_card_"])return nil;NSMutableArray *items=[NSMutableArray new];NSDictionary *own=nil;for(NSDictionary *r in rows)if([r[@"id"]isEqual:ident])own=r;else[items addObject:r];if(![own[@"type"]isEqual:@"a2ui"])return nil;[items insertObject:own atIndex:0];NSMutableDictionary *copy=[s mutableCopy];copy[@"widgets_v2"]=items;NSData *json=[NSJSONSerialization dataWithJSONObject:copy options:NSJSONWritingSortedKeys error:nil];NSDictionary *packet=@{@"cmd":@"dashboard_update",@"payload":@{@"version":@1,@"value":@0,@"data":[[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding]}};return TDCRequest(1,packet)?packet:nil;}
#endif
BOOL TCEVerifyOrder(NSDictionary *a,NSDictionary *b,NSString *ident){NSArray *x=Rows(a),*y=Rows(b);if(!x||!y||!y.count||![y[0][@"id"]isEqual:ident])return NO;NSPredicate *p=[NSPredicate predicateWithBlock:^BOOL(id r,NSDictionary *bindings){return ![r[@"id"]isEqual:ident];}];if(![[x filteredArrayUsingPredicate:p]isEqual:[y filteredArrayUsingPredicate:p]])return NO;NSMutableDictionary *m=[a mutableCopy],*n=[b mutableCopy];[m removeObjectForKey:@"widgets_v2"];[n removeObjectForKey:@"widgets_v2"];return [m isEqual:n];}
#ifndef TCE_DIAGNOSTIC_TEST
static NSDictionary *Component(NSString *id_,NSString *kind,int x,int y,int w,int h,NSDictionary *attrs){NSMutableDictionary *c=[@{@"id":id_,@"kind":kind,@"x":@(x),@"y":@(y),@"w":@(w),@"h":@(h)}mutableCopy];[c addEntriesFromDictionary:attrs];return c;}
static NSDictionary *Text(NSString *id_,NSString *s,int x,int y,int w,int font){return Component(id_,@"text",x,y,w,font+4,@{@"text":s,@"font":@(font),@"align":@"left"});}
NSArray *TCETemplateNames(void){return @[@"资源与额度",@"双列指标",@"大数字",@"柱状图",@"趋势折线",@"文字便笺"];}
NSDictionary *TCETemplate(NSUInteger i,NSString *ident){NSArray *items=nil;
 if(i==0)items=@[Component(@"i1",@"icon",6,12,32,32,@{@"icon":@0}),Text(@"t1",@"Codex Pro 20x",44,6,200,18),Text(@"v1",@"Weekly 99%",44,32,200,16),Component(@"p1",@"progress",44,56,200,4,@{@"value":@99}),Component(@"i2",@"icon",6,76,32,32,@{@"icon":@1}),Text(@"t2",@"Claude Max 20x",44,68,200,18),Text(@"v2",@"5h 90% / Week 85%",44,94,200,16),Component(@"p2",@"progress",44,118,200,4,@{@"value":@85}),Component(@"i3",@"icon",6,148,32,32,@{@"icon":@2}),Text(@"t3",@"MacBook Pro · M5 Max",44,132,200,14),Text(@"v3",@"RAM 37.5 / 128 GB",44,152,200,14),Text(@"v4",@"SSD 1.4 / 2 TB",44,170,200,14)];
 else if(i==1)items=@[Text(@"title",@"今日概览",10,8,232,20),Text(@"a",@"专注",10,48,104,16),Text(@"b",@"阅读",136,48,104,16),Text(@"av",@"75%",10,78,104,28),Text(@"bv",@"90%",136,78,104,28),Component(@"ap",@"progress",10,126,104,8,@{@"value":@75}),Component(@"bp",@"progress",136,126,104,8,@{@"value":@90})];
 else if(i==2)items=@[Component(@"icon",@"icon",10,10,48,48,@{@"icon":@4}),Text(@"title",@"内存余量",72,18,170,20),Text(@"value",@"37.5 GB",16,78,220,28),Component(@"bar",@"progress",16,134,224,8,@{@"value":@29}),Text(@"note",@"总量 128 GB · 演示",16,158,224,16)];
 else if(i==3||i==4)items=@[Text(@"title",i==3?@"本周专注":@"额度趋势",10,8,232,20),Component(@"chart",i==3?@"barChart":@"lineChart",10,42,232,104,@{@"points":@[@25,@48,@35,@72,@65,@90,@85]}),Text(@"note",@"0–100 · 静态示例",10,162,232,16)];
 else items=@[Text(@"title",@"给今天的一句话",12,12,228,20),Component(@"rule",@"divider",12,44,228,2,@{}),Text(@"a",@"专注一件事",12,64,228,24),Text(@"b",@"让好想法慢慢发生",12,104,228,18),Text(@"c",@"Turbo IO",12,152,228,16)];
 return @{@"schema":@1,@"id":ident,@"name":TCETemplateNames()[MIN(i,5)],@"components":items};
}
#endif
