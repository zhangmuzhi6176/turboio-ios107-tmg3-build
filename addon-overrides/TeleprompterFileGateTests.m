#import "TeleprompterFileGate.h"
#include <assert.h>
#include <stdio.h>
#include <unistd.h>

static NSString *const Peer=@"PRIVATE_PEER";
static NSString *const Doc=@"PRIVATE_DOCUMENT-not-a-uuid";
static NSString *const Text=@"PRIVATE_MANUSCRIPT 中文\n第二行";
static NSData *Packet(unsigned type,NSDictionary *j){NSData *d=[NSJSONSerialization dataWithJSONObject:j options:0 error:nil];uint8_t h[]={8,1,16,type,26};NSMutableData *p=[NSMutableData dataWithBytes:h length:5];NSUInteger n=d.length;do{uint8_t b=n&127;n>>=7;if(n)b|=128;[p appendBytes:&b length:1];}while(n);[p appendData:d];return p;}
static NSDictionary *Prepare(NSString *peer,NSString *did,NSUInteger size,NSUInteger mode){return @{@"deviceId":peer,@"businessId":@20,@"payload":Packet(2,@{@"action":@1,@"did":did,@"total":@(size),@"scroll":@(mode)})};}
static NSDictionary *File(NSString *path){return @{@"deviceId":Peer,@"taskId":Doc,@"filePath":path};}
static void Arm(TIOTeleprompterFileGate *g,NSUInteger size){[g observeMethod:@"rayneonet_sendMessage" arguments:Prepare(Peer,Doc,size,2) otaStage:0 uptime:10];assert([g.diagnostic[@"armed"]boolValue]);}
static BOOL Send(TIOTeleprompterFileGate *g,NSDictionary *a){return [g allowsMethod:@"rayneonet_sendFile" arguments:a otaStage:0 uptime:11];}
static void Private(TIOTeleprompterFileGate *g,NSString *path){NSString *json=[[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:g.diagnostic options:0 error:nil] encoding:NSUTF8StringEncoding];for(NSString *secret in @[Peer,Doc,Text,path])assert(![json containsString:secret]);assert([json containsString:@"TELE-FILE-FIX01"]);}
int main(void){@autoreleasepool{
 NSFileManager *fm=NSFileManager.defaultManager;NSString *root=[NSTemporaryDirectory()stringByAppendingPathComponent:[@"tele-gate-test-"stringByAppendingString:NSUUID.UUID.UUIDString]];
 assert([fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);NSString *path=[root stringByAppendingPathComponent:Doc];NSData *body=[Text dataUsingEncoding:NSUTF8StringEncoding];assert([body writeToFile:path atomically:YES]);
 TIOTeleprompterFileGate *g=[[TIOTeleprompterFileGate alloc]initWithContainer:root];
 assert(!Send(g,File(path)));Private(g,path);
 // Official scroll modes, optional checksum and non-UUID manuscript names.
 for(NSUInteger mode=1;mode<=3;mode++){[g observeMethod:@"rayneonet_sendMessage" arguments:Prepare(Peer,Doc,body.length,mode) otaStage:0 uptime:10];assert(Send(g,File(path)));assert(!Send(g,File(path)));Private(g,path);}
 // The AI-news sender uses the same prepare/file contract without a scope token.
 Arm(g,body.length);assert(Send(g,File(path)));assert(![g.diagnostic[@"armed"]boolValue]);
 Arm(g,body.length);NSMutableDictionary *wrong=[File(path)mutableCopy];wrong[@"taskId"]=@"different";assert(!Send(g,wrong));assert(!Send(g,File(path)));assert([g.diagnostic[@"reason"]isEqual:@"task_mismatch"]);
 Arm(g,body.length);wrong=[File(path)mutableCopy];wrong[@"deviceId"]=@"other";assert(!Send(g,wrong));
 Arm(g,body.length);wrong=[File(path)mutableCopy];wrong[@"extra"]=@YES;assert(!Send(g,wrong));
 Arm(g,body.length+1);assert(!Send(g,File(path)));assert([g.diagnostic[@"reason"]isEqual:@"byte_count_mismatch"]);
 Arm(g,body.length);assert(![g allowsMethod:@"rayneonet_sendFile" arguments:File(path) otaStage:0 uptime:130]);assert([g.diagnostic[@"reason"]isEqual:@"prepare_expired"]);
 Arm(g,body.length);assert(![g allowsMethod:@"rayneonet_sendFile" arguments:File(path) otaStage:1 uptime:11]);assert(!Send(g,File(path)));
 Arm(g,body.length);[g observeMethod:@"rayneonet_disconnect" arguments:@{@"deviceId":Peer} otaStage:0 uptime:11];assert(!Send(g,File(path)));
 Arm(g,body.length);[g observeEvent:@{@"eventType":@"bleStateChange",@"device":@{@"id":Peer},@"newState":@"disconnected"} uptime:11];assert(!Send(g,File(path)));
 Arm(g,body.length);[g observeEvent:@{@"eventType":@"messageReceived",@"message":@{@"deviceId":@"another-device",@"businessId":@7}} uptime:11];assert(!Send(g,File(path)));
 Arm(g,body.length);[g observeMethod:@"rayneonet_sendMessage" arguments:@{@"deviceId":Peer,@"businessId":@20,@"payload":Packet(6,@{@"action":@1,@"did":Doc})} otaStage:0 uptime:11];assert(!Send(g,File(path)));
 Arm(g,body.length);[g observeEvent:@{@"eventType":@"messageReceived",@"message":@{@"deviceId":Peer,@"businessId":@20,@"payload":Packet(2,@{@"action":@2,@"did":Doc,@"code":@0})}} uptime:11];assert(!Send(g,File(path)));
 Arm(g,body.length);[g observeMethod:@"rayneonet_sendMessage" arguments:Prepare(Peer,@"another-document",body.length,2) otaStage:0 uptime:11];assert(!Send(g,File(path)));
 // A business-9 OTA payload never arms the exception; OTA methods never pass.
 [g invalidate];NSMutableDictionary *ota=[Prepare(Peer,Doc,body.length,2)mutableCopy];ota[@"businessId"]=@9;[g observeMethod:@"rayneonet_sendMessage" arguments:ota otaStage:0 uptime:10];assert(!Send(g,File(path)));
 Arm(g,body.length);assert(![g allowsMethod:@"rayneonet_startOTA" arguments:File(path) otaStage:0 uptime:11]);assert(![g allowsMethod:@"rayneonet_sendFileAlternate" arguments:File(path) otaStage:0 uptime:11]);
 for(NSUInteger stage=1;stage<=3;stage++){[g observeMethod:@"rayneonet_sendMessage" arguments:Prepare(Peer,Doc,body.length,2) otaStage:stage uptime:10];assert(!Send(g,File(path)));}
 // Existing local maximum is not imposed on official long manuscripts.
 NSData *longText=[[@"x" stringByPaddingToLength:50001 withString:@"x" startingAtIndex:0]dataUsingEncoding:NSUTF8StringEncoding];assert([longText writeToFile:path atomically:YES]);Arm(g,longText.length);assert(Send(g,File(path)));
 [g observeMethod:@"rayneonet_sendMessage" arguments:Prepare(Peer,Doc,1024*1024+1,2) otaStage:0 uptime:10];assert(!Send(g,File(path)));assert([g.diagnostic[@"reason"]isEqual:@"local_size_limit"]);
 NSData *hello=[@"hello"dataUsingEncoding:NSUTF8StringEncoding];assert([hello writeToFile:path atomically:YES]);
 NSDictionary *(^withChecksum)(NSString *)=^NSDictionary *(NSString *hash){return @{@"deviceId":Peer,@"businessId":@20,@"payload":Packet(2,@{@"action":@1,@"did":Doc,@"total":@5,@"scroll":@2,@"checksum":hash})};};
 [g observeMethod:@"rayneonet_sendMessage" arguments:withChecksum(@"4F9F2CAB") otaStage:0 uptime:10];assert(Send(g,File(path)));
 [g observeMethod:@"rayneonet_sendMessage" arguments:withChecksum(@"") otaStage:0 uptime:10];assert(Send(g,File(path)));
 for(id invalid in @[@1,NSNull.null,@"not-a-hash"]){[g observeMethod:@"rayneonet_sendMessage" arguments:withChecksum(invalid) otaStage:0 uptime:10];assert(!Send(g,File(path)));assert([g.diagnostic[@"reason"]isEqual:@"invalid_checksum"]);}
 [g observeMethod:@"rayneonet_sendMessage" arguments:withChecksum(@"00000000") otaStage:0 uptime:10];assert(!Send(g,File(path)));assert([g.diagnostic[@"reason"]isEqual:@"checksum_mismatch"]);
 uint8_t badUTF[]={0xff,0xfe};uint8_t zip[]={0x50,0x4b,0x03,0x04};uint8_t nul[]={0x41,0x00,0x42};
 for(NSData *bad in @[[NSData dataWithBytes:badUTF length:sizeof badUTF],[NSData dataWithBytes:zip length:sizeof zip],[NSData dataWithBytes:nul length:sizeof nul]]){assert([bad writeToFile:path atomically:YES]);Arm(g,bad.length);assert(!Send(g,File(path)));assert([g.diagnostic[@"reason"]isEqual:@"not_utf8_text"]);}
 assert([body writeToFile:path atomically:YES]);
 NSString *otaDir=[root stringByAppendingPathComponent:@"Library/Application Support/ota/test-version"];assert([fm createDirectoryAtPath:otaDir withIntermediateDirectories:YES attributes:nil error:nil]);NSString *otaText=[otaDir stringByAppendingPathComponent:Doc];assert([body writeToFile:otaText atomically:YES]);Arm(g,body.length);assert(!Send(g,File(otaText)));assert([g.diagnostic[@"reason"]isEqual:@"reserved_ota_carrier"]);
 for(NSString *reserved in @[@"OtaFileInfo.json",@"firmware.zip",@"smf.json",@"pil_algo_vad_demo.dll"]){NSString *reservedPath=[root stringByAppendingPathComponent:reserved];NSData *json=[@"[]"dataUsingEncoding:NSUTF8StringEncoding];assert([json writeToFile:reservedPath atomically:YES]);[g observeMethod:@"rayneonet_sendMessage" arguments:Prepare(Peer,reserved,json.length,2) otaStage:0 uptime:10];assert((![g allowsMethod:@"rayneonet_sendFile" arguments:@{@"deviceId":Peer,@"taskId":reserved,@"filePath":reservedPath} otaStage:0 uptime:11]));assert([g.diagnostic[@"reason"]isEqual:@"reserved_ota_carrier"]);}
 Arm(g,body.length);assert(!Send(g,File([root stringByAppendingPathComponent:[@"../"stringByAppendingString:Doc]])));
 Arm(g,body.length);assert(!Send(g,File([root stringByAppendingPathComponent:@"different-name"])));
 NSString *outside=[root stringByAppendingString:@"-outside"];assert([fm createDirectoryAtPath:outside withIntermediateDirectories:YES attributes:nil error:nil]);NSString *external=[outside stringByAppendingPathComponent:Doc];assert([body writeToFile:external atomically:YES]);Arm(g,body.length);assert(!Send(g,File(external)));
 assert([fm removeItemAtPath:path error:nil]);assert([fm createSymbolicLinkAtPath:path withDestinationPath:external error:nil]);Arm(g,body.length);assert(!Send(g,File(path)));assert([fm removeItemAtPath:path error:nil]);assert([body writeToFile:path atomically:YES]);
 NSString *sub=[root stringByAppendingPathComponent:@"linked-parent"];assert([fm createSymbolicLinkAtPath:sub withDestinationPath:outside error:nil]);Arm(g,body.length);assert(!Send(g,File([sub stringByAppendingPathComponent:Doc])));
 // A trusted container root alias is resolved before checking its descendants.
 NSString *alias=[root stringByAppendingString:@"-alias"];assert([fm createSymbolicLinkAtPath:alias withDestinationPath:root error:nil]);TIOTeleprompterFileGate *aliasGate=[[TIOTeleprompterFileGate alloc]initWithContainer:alias];Arm(aliasGate,body.length);assert(Send(aliasGate,File([alias stringByAppendingPathComponent:Doc])));Arm(aliasGate,body.length);assert(Send(aliasGate,File([root.stringByResolvingSymlinksInPath stringByAppendingPathComponent:Doc])));
 // Hard links and nonregular files cannot be used as manuscript carriers.
 assert([fm removeItemAtPath:path error:nil]);assert(link(external.fileSystemRepresentation,path.fileSystemRepresentation)==0);Arm(g,body.length);assert(!Send(g,File(path)));assert([fm removeItemAtPath:path error:nil]);assert([fm createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:nil]);Arm(g,body.length);assert(!Send(g,File(path)));
 Private(g,path);Private(aliasGate,path);
 assert([fm removeItemAtPath:alias error:nil]);assert([fm removeItemAtPath:root error:nil]);assert([fm removeItemAtPath:outside error:nil]);
 printf("teleprompter bound file gate: PASS\n");
}return 0;}
