import 'dart:async';
import 'dart:convert';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'radio_api.dart';

class RadioHandler extends BaseAudioHandler {
  final player=AudioPlayer();
  final api=RadioApi();
  List<Station> _active=[];
  Station? current;
  int _generation=0;
  RadioHandler(){
    player.playbackEventStream.listen((_)=>_broadcast(),onError:(Object e,StackTrace st){
      playbackState.add(playbackState.value.copyWith(processingState:AudioProcessingState.error,errorMessage:e.toString(),playing:false));
    });
  }
  void _broadcast(){
    playbackState.add(PlaybackState(
      controls:[MediaControl.skipToPrevious,player.playing?MediaControl.pause:MediaControl.play,MediaControl.skipToNext,MediaControl.stop],
      androidCompactActionIndices:const [0,1,2],
      processingState:const {ProcessingState.idle:AudioProcessingState.idle,ProcessingState.loading:AudioProcessingState.loading,ProcessingState.buffering:AudioProcessingState.buffering,ProcessingState.ready:AudioProcessingState.ready,ProcessingState.completed:AudioProcessingState.completed}[player.processingState]!,
      playing:player.playing,updatePosition:player.position,bufferedPosition:player.bufferedPosition,speed:player.speed));
  }
  MediaItem item(Station s)=>MediaItem(id:s.id,title:s.name,album:s.country,artUri:s.logo.startsWith('http')?Uri.tryParse(s.logo):null,extras:{'url':s.url,'country':s.country,'logo':s.logo});
  Station station(MediaItem m)=>Station(m.id,m.title,m.extras?['url'] as String? ?? '',m.extras?['country'] as String? ?? '',m.extras?['logo'] as String? ?? '');
  Future<List<Station>> stored(String key) async {
    final p=await SharedPreferences.getInstance();await p.reload();
    return (jsonDecode(p.getString(key)??'[]') as List).map((j)=>Station.fromJson(Map<String,dynamic>.from(j))).toList();
  }
  @override Future<List<MediaItem>> getChildren(String parentMediaId,[Map<String,dynamic>? options]) async {
    if(parentMediaId==AudioService.browsableRootId){
      final p=await SharedPreferences.getInstance();await p.reload();
      final lang=p.getString('language')??'en';
      String tr(String en,String sv,String hr)=>lang=='sv'?sv:lang=='hr'?hr:en;
      return [MediaItem(id:'favorites',title:tr('Favorites','Favoriter','Omiljene'),playable:false),MediaItem(id:'recent',title:tr('Recent','Senaste','Nedavno'),playable:false),MediaItem(id:'popular',title:tr('Popular stations','Populära stationer','Popularne stanice'),playable:false)];
    }
    try{
      final list=parentMediaId=='favorites'||parentMediaId=='recent'?await stored(parentMediaId):parentMediaId=='popular'?await api.search('',''):<Station>[];
      return list.take(100).map(item).toList();
    }catch(_){return [];}
  }
  @override Future<MediaItem?> getMediaItem(String mediaId) async {
    if(current?.id==mediaId)return item(current!);
    for(final key in ['favorites','recent','popular']){
      for(final m in await getChildren(key)){if(m.id==mediaId)return m;}
    }
    return null;
  }
  @override Future<void> playFromMediaId(String mediaId,[Map<String,dynamic>? extras]) async {
    for(final key in ['favorites','recent','popular']){
      final list=await getChildren(key);
      for(final m in list){if(m.id==mediaId){await select(station(m),list.map(station).toList());return;}}
    }
  }
  @override Future<void> playMediaItem(MediaItem mediaItem) async => select(station(mediaItem),[station(mediaItem)]);
  Future<void> select(Station s,List<Station> list) async {
    final generation=++_generation;
    _active=list.isEmpty?[s]:List.of(list);
    current=s;mediaItem.add(item(s));
    try{
      await player.setUrl(s.url);
      if(generation!=_generation)return;
      final p=await SharedPreferences.getInstance();
      final recent=[s,...(await stored('recent')).where((x)=>x.id!=s.id)].take(50);
      await p.setString('recent',jsonEncode(recent.map((x)=>x.toJson()).toList()));
      notifyChildrenChanged('recent');
      unawaited(player.play().catchError((Object e){if(generation==_generation)playbackState.add(playbackState.value.copyWith(processingState:AudioProcessingState.error,errorMessage:e.toString(),playing:false));}));
    }catch(e){if(generation==_generation){playbackState.add(playbackState.value.copyWith(processingState:AudioProcessingState.error,errorMessage:e.toString(),playing:false));rethrow;}}
  }
  @override Future<void> play() async {if(current!=null)unawaited(player.play());}
  @override Future<void> pause()=>player.pause();
  @override Future<void> stop() async {await player.stop();await super.stop();}
  Future<void> _skip(int delta) async {if(_active.isEmpty)return;final i=_active.indexWhere((s)=>s.id==current?.id);await select(_active[(i+delta+_active.length)%_active.length],_active);}
  @override Future<void> skipToNext()=>_skip(1);
  @override Future<void> skipToPrevious()=>_skip(-1);
  @override Future<void> playFromSearch(String query,[Map<String,dynamic>? extras]) async {final list=await api.search(query,'');if(list.isNotEmpty)await select(list.first,list);}
  @override Future<List<MediaItem>> search(String query,[Map<String,dynamic>? extras]) async => (await api.search(query,'')).map(item).toList();
}
