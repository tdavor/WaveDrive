import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'radio_api.dart';

/// Local, read-only artwork URIs for Android Auto; network images are decoded
/// into small PNGs before they are exposed by StationArtworkProvider.
class CarArtwork {
  CarArtwork(this.fallback);
  final Uri? fallback;
  final _pending=<String,Future<bool>>{};
  final _failed=<String>{};
  final _jobs=<Future<void> Function()>[];
  int _running=0;
  static const _authority='com.wavedrive.wavedrive.artwork';
  String _key(Station s)=>base64Url.encode(utf8.encode(s.id)).replaceAll('=','');
  Uri get logo=>Uri(scheme:'content',host:_authority,path:'/logo');
  Uri uri(Station s){
    final key=_key(s);
    return key.isEmpty||key.length>180?logo:Uri(scheme:'content',host:_authority,path:'/$key',queryParameters:{'v':_file(s)?.existsSync()==true?'1':'0'});
  }
  File? _file(Station s){
    if(fallback==null||fallback!.scheme!='file')return null;
    final key=_key(s);
    if(key.isEmpty||key.length>180)return null;
    return File('${File.fromUri(fallback!).parent.path}/car_artwork/$key.png');
  }
  String? localPath(Station s){
    final file=_file(s);
    return file!=null&&file.existsSync()?file.path:fallback?.toFilePath();
  }
  Future<bool> prepare(Station s){
    final file=_file(s);
    final url=Uri.tryParse(s.logo.trim());
    if(file==null||url==null||!['http','https'].contains(url.scheme)||url.host.isEmpty||file.existsSync()||_failed.contains(s.id))return Future.value(false);
    final existing=_pending[s.id];if(existing!=null)return existing;
    final completer=Completer<bool>();
    _pending[s.id]=completer.future;
    _jobs.add(() async {
      bool changed=false;
      try{changed=await _download(url,file);}
      catch(e){debugPrint('WaveDrive artwork: $e');}
      finally{
        if(!changed)_failed.add(s.id);
        _pending.remove(s.id);
        completer.complete(changed);
      }
    });
    _pump();
    return completer.future;
  }
  void _pump(){
    while(_running<6&&_jobs.isNotEmpty){
      final job=_jobs.removeAt(0);_running++;
      unawaited(job().whenComplete((){_running--;_pump();}));
    }
  }
  Future<bool> _download(Uri url,File file) async {
    final client=HttpClient()..connectionTimeout=const Duration(seconds:3);
    try{
      final request=await client.getUrl(url).timeout(const Duration(seconds:4));
      request.headers.set('User-Agent','WaveDrive');
      final response=await request.close().timeout(const Duration(seconds:4));
      if(response.statusCode!=200||response.contentLength>2*1024*1024)return false;
      final bytes=BytesBuilder(copy:false);
      await response.timeout(const Duration(seconds:4)).forEach((chunk){
        if(bytes.length+chunk.length>2*1024*1024)throw StateError('Artwork too large');
        bytes.add(chunk);
      }).timeout(const Duration(seconds:6));
      final codec=await ui.instantiateImageCodec(bytes.takeBytes(),targetWidth:256,targetHeight:256);
      try{
        final frame=await codec.getNextFrame();
        try{
          final png=await frame.image.toByteData(format:ui.ImageByteFormat.png);
          if(png==null)return false;
          await file.parent.create(recursive:true);
          final temp=File('${file.path}.tmp');
          await temp.writeAsBytes(png.buffer.asUint8List(png.offsetInBytes,png.lengthInBytes),flush:true);
          await temp.rename(file.path);
          return true;
        }finally{frame.image.dispose();}
      }finally{codec.dispose();}
    }finally{client.close(force:true);}
  }
}
