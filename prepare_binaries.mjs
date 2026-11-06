// Uses pinned upstream pure binary functions; no signing or external tools.
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
const [edition,app,addon,reportFile]=process.argv.slice(2);
const check=(x,m)=>{if(!x)throw Error(m);};
check([edition,app,reportFile].every(x=>x&&path.isAbsolute(x)),'absolute_paths_required');
const {inspectMachO,addEmbeddedLoad}=await import(pathToFileURL(path.join(edition,'macho-embed.mjs')));
const {patch,verifyRoute}=await import(pathToFileURL(path.join(edition,'patch-route.mjs')));
const sha=b=>createHash('sha256').update(b).digest('hex');
const runnerFile=path.join(app,'Runner'),appFile=path.join(app,'Frameworks/App.framework/App');
const runner=fs.readFileSync(runnerFile),appImage=fs.readFileSync(appFile);
check(sha(runner)==='765715adebb3b6132a1870d9b500e861e028cdaecc2f6485296a428c1812e0b3','runner_identity');
check(sha(appImage)==='041dc97ad3a864ac322e92a49d3b1ebbd466d371dc427591b0b82c8c56b5090d','app_image_identity');
const header=inspectMachO(runner);
check(header.uuid==='410defdbf93739eaacf2f616abff9d0b'&&!header.encrypted,'runner_uuid_or_encryption');
const inventory=[];
function walk(dir){for(const entry of fs.readdirSync(dir,{withFileTypes:true})){
  const p=path.join(dir,entry.name);
  check(!entry.isSymbolicLink(),'symlink_not_supported');
  if(entry.isDirectory()){check(entry.name!=='PlugIns','unexpected_extensions');walk(p);continue;}
  const b=fs.readFileSync(p);
  if(b.length<4)continue;
  check(![0xcafebabe,0xbebafeca,0xcafebabf,0xbfbafeca].includes(b.readUInt32BE()),'fat_image_requires_review');
  if(b.readUInt32LE()===0xfeedfacf){const h=inspectMachO(b);check(!h.encrypted,'encrypted_nested_image');inventory.push(path.relative(app,p).replaceAll('\\','/'));}
}}
walk(app);check(inventory.length===95,'source_binary_count');
const preparedRunner=addEmbeddedLoad(runner),route=patch(appImage);
verifyRoute(route.output);
let addonHash=null;
if(addon!=='-'){
  check(path.isAbsolute(addon),'addon_path');
  const data=fs.readFileSync(addon),h=inspectMachO(data);
  check(h.fileType===6&&h.installName==='@rpath/TurboIOPrivateAddon.dylib'&&!h.encrypted,'addon_embedded_type');
  check(!h.dependencies.some(x=>/\/var\/jb\/|frida|ellekit|substrate/i.test(x)),'addon_jailbreak_dependency');
  check(data.includes(Buffer.from('com.turboio.rayneo.tmg3.local\0')),'addon_bundle');
  check(data.includes(Buffer.from('display extension=APP107-TMG3-PHONE-DEV01;')),'addon_marker');
  check(data.includes(Buffer.from('DASH-CONFIG-DIAG01\0')),'dashboard_diagnostic_marker');
  addonHash=sha(data);
  fs.writeFileSync(runnerFile,preparedRunner);
  fs.writeFileSync(appFile,route.output);
  fs.copyFileSync(addon,path.join(app,'Frameworks/TurboIOPrivateAddon.dylib'),fs.constants.COPYFILE_EXCL);
  verifyRoute(fs.readFileSync(appFile));
}
const report={sourceBinaryCount:inventory.length,allSourceImagesUnencrypted:true,sourceRunnerUUID:header.uuid,
  sourceRunnerSHA256:sha(runner),preparedRunnerSHA256:sha(preparedRunner),
  patchedAppSHA256:sha(route.output),addonSHA256:addonHash,route:route.report,
  changedCopy:addon!=='-',signed:false,deviceIO:false,runtimeValidated:false};
fs.writeFileSync(reportFile,JSON.stringify(report,null,2)+'\n',{flag:'wx'});
console.log(JSON.stringify(report));
