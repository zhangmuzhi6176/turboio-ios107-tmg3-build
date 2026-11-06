#import "TeleprompterFileGate.h"
#import "TodoProtocol.h"
#import <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <math.h>
#include <errno.h>
#include <stdint.h>

// Local validation resource ceiling, not a claimed official manuscript limit.
static const NSUInteger LocalByteLimit=1024*1024;
static const NSTimeInterval PrepareLifetime=120;
static BOOL Text(id v){return [v isKindOfClass:NSString.class]&&[v length]>0&&[v length]<=256;}
static BOOL Unsigned(id v,NSUInteger *n){
 if(![v isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)v)==CFBooleanGetTypeID()||CFNumberIsFloatType((__bridge CFNumberRef)v)||[v longLongValue]<0||[v unsignedLongLongValue]>UINT32_MAX)return NO;
 *n=[v unsignedIntegerValue];return YES;
}
static BOOL Is(id v,NSUInteger expected){NSUInteger n=0;return Unsigned(v,&n)&&n==expected;}
static BOOL DID(id v){return Text(v)&&![v isEqual:@"."]&&![v isEqual:@".."]&&[v rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\"]].location==NSNotFound&&[v rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound;}
static NSData *Bytes(id v){if([v isKindOfClass:NSData.class])return v;@try{id d=[v valueForKey:@"data"];return [d isKindOfClass:NSData.class]?d:nil;}@catch(NSException *e){return nil;}}
static BOOL Checksum(id v){return [v isKindOfClass:NSString.class]&&[v length]==8&&[v rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"]invertedSet]].location==NSNotFound;}
static NSString *Hash(NSData *d){uint32_t h=2166136261u;const uint8_t *b=d.bytes;for(NSUInteger i=0;i<d.length;i++)h=(h^b[i])*16777619u;return [NSString stringWithFormat:@"%08x",h];}
static BOOL UTF8Text(NSData *d){
 if(!d.length||![[NSString alloc]initWithData:d encoding:NSUTF8StringEncoding])return NO;
 const uint8_t *b=d.bytes;for(NSUInteger i=0;i<d.length;i++)if((b[i]<32&&b[i]!=9&&b[i]!=10&&b[i]!=13)||b[i]==127)return NO;
 return YES;
}
@implementation TIOTeleprompterFileGate {
 NSString *_container,*resolvedContainer,*device,*did,*checksum,*reason;
 NSUInteger _total;NSTimeInterval _preparedAt;
}
- (instancetype)initWithContainer:(NSString *)container{
 if((self=[super init])){_container=[container stringByStandardizingPath];_resolvedContainer=[_container stringByResolvingSymlinksInPath];_reason=@"no_prepare";}return self;
}
- (void)clear:(NSString *)reason{_device=nil;_did=nil;_checksum=nil;_total=0;_preparedAt=0;_reason=reason;}
- (void)invalidate{@synchronized(self){[self clear:@"invalidated"];}}
- (BOOL)fresh:(NSTimeInterval)now{
 if(!isfinite(now)||now<0){[self clear:@"invalid_time"];return NO;}
 if(_did&&(now<_preparedAt||now-_preparedAt>=PrepareLifetime)){[self clear:@"prepare_expired"];return NO;}
 return _did!=nil;
}
- (void)observeMethod:(NSString *)method arguments:(NSDictionary *)a otaStage:(NSUInteger)stage uptime:(NSTimeInterval)now{
 @synchronized(self){
  if(stage){[self clear:@"ota_active"];return;}[self fresh:now];
  if(![method isKindOfClass:NSString.class])return;
  NSString *lower=method.lowercaseString;
  if([lower containsString:@"disconnect"]||[lower containsString:@"unbind"]||[lower containsString:@"unpair"]){[self clear:@"disconnected"];return;}
  if(![a isKindOfClass:NSDictionary.class])return;
  id peer=a[@"deviceId"];
  if(_device&&Text(peer)&&![_device isEqual:peer])[self clear:@"device_changed"];
  if(![method isEqual:@"rayneonet_sendMessage"]||!Is(a[@"businessId"],20))return;
  NSDictionary *e=TIOTodoEnvelope(Bytes(a[@"payload"]));id j=e[@"json"];
  if(Is(e[@"type"],6)){[self clear:@"prepare_cancelled"];return;}
  if(!Is(e[@"type"],2))return;
  // Every fresh prepare supersedes the previous allowance, including bad input.
  [self clear:@"invalid_prepare"];
  NSUInteger total=0,scroll=0;
  if(!isfinite(now)||now<0||!Text(peer)||![j isKindOfClass:NSDictionary.class]||!Is(j[@"action"],1)||!DID(j[@"did"])||!Unsigned(j[@"total"],&total)||!total||!Unsigned(j[@"scroll"],&scroll)||scroll<1||scroll>3)return;
  if(total>LocalByteLimit){_reason=@"local_size_limit";return;}
  id checksum=j[@"checksum"];
  if(checksum&&(![checksum isKindOfClass:NSString.class]||([checksum length]&&!Checksum(checksum)))){_reason=@"invalid_checksum";return;}
  _device=[peer copy];_did=[j[@"did"]copy];_checksum=[checksum length]?[checksum lowercaseString]:nil;_total=total;_preparedAt=now;_reason=@"prepared";
 }
}
- (void)observeEvent:(NSDictionary *)event uptime:(NSTimeInterval)now{
 @synchronized(self){
  [self fresh:now];if(![event isKindOfClass:NSDictionary.class])return;
  if([event[@"eventType"]isEqual:@"bleStateChange"]){
   id d=event[@"device"];id peer=[d isKindOfClass:NSDictionary.class]?d[@"id"]:nil;id state=event[@"newState"];
   if(Text(peer)&&_device&&![peer isEqual:_device]){[self clear:@"device_changed"];return;}
   if([@[@"disconnected",@"connectFail",@"interrupted",@"connectTimeOut",@"authFailed",@"authInterrupt"]containsObject:state?:NSNull.null]){[self clear:@"disconnected"];return;}
  }
  if(![event[@"eventType"]isEqual:@"messageReceived"]||![event[@"message"]isKindOfClass:NSDictionary.class])return;
  NSDictionary *m=event[@"message"];id peer=m[@"deviceId"];
  if(_device&&Text(peer)&&![peer isEqual:_device]){[self clear:@"device_changed"];return;}
  if(!_device||![peer isEqual:_device]||!Is(m[@"businessId"],20))return;
  NSDictionary *e=TIOTodoEnvelope(Bytes(m[@"payload"]));NSDictionary *j=e[@"json"];
  if(Is(e[@"type"],6)&&[j[@"did"]isEqual:_did])[self clear:@"prepare_cancelled"];
  else if(Is(e[@"type"],2)&&[j[@"did"]isEqual:_did]&&Is(j[@"action"],2)&&j[@"code"]&&!Is(j[@"code"],1)&&!Is(j[@"code"],7))[self clear:@"prepare_rejected"];
 }
}
- (BOOL)fileAtPath:(id)path matches:(NSString *)did total:(NSUInteger)total checksum:(NSString *)checksum{
 if(![path isKindOfClass:NSString.class]||![path isAbsolutePath]||[path length]>4096||!_resolvedContainer.length){_reason=@"invalid_path";return NO;}
 NSString *relative=nil;
 // The trusted container itself may use the system /var -> /private/var alias.
 // Below that root, every component is opened with O_NOFOLLOW.
 for(NSString *root in @[_container?:@"",_resolvedContainer?:@""]){NSString *prefix=[root stringByAppendingString:@"/"];if([path hasPrefix:prefix]){relative=[path substringFromIndex:prefix.length];break;}}
 if(!relative.length){_reason=@"outside_container";return NO;}
 NSString *lower=relative.lowercaseString;
 // Exact 1.0.5.12 package member names, including its textual manifests.
 NSArray *otaNames=@[@"otafileinfo.json",@"bt_controller.bin",@"cb_fw_venus.bin",@"fac_test_img.bin",@"images.bin",@"lotties.bin",@"nuttx_ap.bin",@"nuttx_apc1.bin",@"nuttx_audio.bin",@"nuttx_bth.bin",@"ota_installer_progress.bin",@"pil_algo_up_demo_nand.dll",@"pil_algo_vad_demo.dll",@"pil_algo_wakeup_dll_nand.dll",@"rives.bin",@"smf.json"];
 if([lower hasPrefix:@"library/application support/ota/"]||[otaNames containsObject:lower.lastPathComponent]||[@[@"zip",@"bin",@"img",@"ota"]containsObject:lower.pathExtension]){_reason=@"reserved_ota_carrier";return NO;}
 NSArray *parts=[relative componentsSeparatedByString:@"/"];
 for(NSString *part in parts)if(!part.length||[part isEqual:@"."]||[part isEqual:@".."]||[part rangeOfString:@"\\"].location!=NSNotFound||[part rangeOfString:[NSString stringWithFormat:@"%C",(unichar)0]].location!=NSNotFound){_reason=@"invalid_path_component";return NO;}
 if(![parts.lastObject isEqual:did]){_reason=@"basename_mismatch";return NO;}
 int directory=open(_resolvedContainer.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
 if(directory<0){_reason=@"container_unavailable";return NO;}
 for(NSUInteger i=0;i+1<parts.count;i++){int next=openat(directory,[parts[i]fileSystemRepresentation],O_RDONLY|O_DIRECTORY|O_NOFOLLOW);close(directory);directory=next;if(directory<0){_reason=@"unsafe_path_component";return NO;}}
 int fd=openat(directory,[parts.lastObject fileSystemRepresentation],O_RDONLY|O_NOFOLLOW|O_NONBLOCK);
 if(fd<0){close(directory);_reason=@"file_unavailable_or_link";return NO;}
 BOOL valid=NO;struct stat before,after,pathState;NSMutableData *bytes=nil;
 do{
  if(fstat(fd,&before)||!S_ISREG(before.st_mode)||before.st_nlink!=1){_reason=@"not_regular_file";break;}
  if(before.st_size!=(off_t)total){_reason=@"byte_count_mismatch";break;}
  bytes=[NSMutableData dataWithLength:total];NSUInteger used=0;
  while(used<total){ssize_t got=read(fd,(uint8_t *)bytes.mutableBytes+used,total-used);if(got<0&&errno==EINTR)continue;if(got<=0)break;used+=(NSUInteger)got;}
  uint8_t extra;ssize_t tail;do{tail=read(fd,&extra,1);}while(tail<0&&errno==EINTR);
  if(used!=total||tail!=0||fstat(fd,&after)||fstatat(directory,[parts.lastObject fileSystemRepresentation],&pathState,AT_SYMLINK_NOFOLLOW)||!S_ISREG(pathState.st_mode)||before.st_dev!=after.st_dev||before.st_ino!=after.st_ino||before.st_size!=after.st_size||before.st_mtimespec.tv_sec!=after.st_mtimespec.tv_sec||before.st_mtimespec.tv_nsec!=after.st_mtimespec.tv_nsec||before.st_dev!=pathState.st_dev||before.st_ino!=pathState.st_ino){_reason=@"file_changed";break;}
  if(!UTF8Text(bytes)){_reason=@"not_utf8_text";break;}
  if(checksum&&![Hash(bytes)isEqual:checksum]){_reason=@"checksum_mismatch";break;}
  valid=YES;
 }while(0);
 close(fd);close(directory);return valid;
}
- (BOOL)allowsMethod:(NSString *)method arguments:(NSDictionary *)a otaStage:(NSUInteger)stage uptime:(NSTimeInterval)now{
 @synchronized(self){
  if(stage){[self clear:@"ota_active"];return NO;}
  if(![method isEqual:@"rayneonet_sendFile"]){_reason=@"not_send_file";return NO;}
  if(![self fresh:now])return NO;
  // A send attempt consumes the prepare even on failure; retry needs new prepare.
  NSString *peer=_device,*did=_did,*checksum=_checksum;NSUInteger total=_total;[self clear:@"invalid_file_arguments"];
  if(![a isKindOfClass:NSDictionary.class]||![[NSSet setWithArray:a.allKeys]isEqual:[NSSet setWithArray:@[@"deviceId",@"taskId",@"filePath"]]])return NO;
  if(![a[@"deviceId"]isEqual:peer]){_reason=@"device_mismatch";return NO;}
  if(![a[@"taskId"]isEqual:did]){_reason=@"task_mismatch";return NO;}
  if(![self fileAtPath:a[@"filePath"] matches:did total:total checksum:checksum])return NO;
  _reason=@"allowed_once";return YES;
 }
}
- (NSDictionary *)diagnostic{@synchronized(self){return @{@"build":@"TELE-FILE-FIX01",@"reason":_reason?:@"no_prepare",@"armed":@(_did!=nil)};}}
@end
