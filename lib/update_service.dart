import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class WaveUpdate {
  final String version,url;
  const WaveUpdate(this.version,this.url);
}

class UpdateService {
  static const _native=MethodChannel('wavedrive/update');
  static const _repo='https://github.com/tdavor/WaveDrive/releases/download/';
  static List<int>? _version(String value){
    final m=RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-alpha\.(\d+))?$').firstMatch(value);
    if(m==null)return null;
    return [int.parse(m[1]!),int.parse(m[2]!),int.parse(m[3]!),m[4]==null?1:0,int.parse(m[4]??'0')];
  }
  static int _compare(List<int> a,List<int> b){
    for(var i=0;i<a.length;i++){final c=a[i].compareTo(b[i]);if(c!=0)return c;}
    return 0;
  }
  Future<WaveUpdate?> check(String installed) async {
    final device=await _native.invokeMapMethod<String,dynamic>('device');
    final arch=const {'arm64-v8a':'arm64','armeabi-v7a':'arm32','x86_64':'x86_64'}[device?['abi']];
    if(arch==null)return null;
    final current=_version(installed);
    if(current==null)return null;
    final response=await http.get(Uri.https('api.github.com','/repos/tdavor/WaveDrive/releases',{'per_page':'30'}),headers:{'Accept':'application/vnd.github+json','User-Agent':'WaveDrive'}).timeout(const Duration(seconds:12));
    if(response.statusCode!=200)throw Exception('GitHub HTTP ${response.statusCode}');
    WaveUpdate? best;
    var bestVersion=current;
    for(final release in jsonDecode(response.body) as List){
      if(release['draft']==true)continue;
      final tag=release['tag_name'] as String? ?? '';
      final parsed=_version(tag);
      if(parsed==null||_compare(parsed,bestVersion)<=0)continue;
      final expected='WaveDrive-${tag.startsWith('v')?tag:'v$tag'}-$arch.apk';
      for(final asset in (release['assets'] as List? ?? [])){
        if(asset['name']!=expected)continue;
        final url=asset['browser_download_url'] as String? ?? '';
        if(url!='$_repo$tag/$expected')continue;
        best=WaveUpdate(tag,url);bestVersion=parsed;break;
      }
    }
    return best;
  }
  Future<void> download(WaveUpdate update) async {await _native.invokeMethod<bool>('download',{'url':update.url});}
  Future<String?> install()=>_native.invokeMethod<String>('install');
}
