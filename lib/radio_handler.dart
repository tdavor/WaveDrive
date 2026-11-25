import 'dart:async';
import 'dart:convert';
import 'package:rxdart/rxdart.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'radio_api.dart';

class RadioHandler extends BaseAudioHandler {
  final _children=<String,BehaviorSubject<Map<String,dynamic>>>{};
  BehaviorSubject<Map<String,dynamic>> _subject(String id)=>_children.putIfAbsent(id,()=>BehaviorSubject.seeded(<String,dynamic>{}));
  @override ValueStream<Map<String,dynamic>> subscribeToChildren(String parentMediaId)=>_subject(parentMediaId);
  void refreshChildren(String id)=>_subject(id).add(<String,dynamic>{});
  final player=AudioPlayer(audioLoadConfiguration:const AudioLoadConfiguration(androidLoadControl:AndroidLoadControl(minBufferDuration:Duration(seconds:30),maxBufferDuration:Duration(seconds:60),bufferForPlaybackDuration:Duration(seconds:2),bufferForPlaybackAfterRebufferDuration:Duration(seconds:4))));
  final api=RadioApi();
  List<Station> _active=[];
  Station? current;
  int _generation=0;
  bool _wanted=false, _opening=false, _recovering=false;
  int _attempt=0;
  String? _failure;
  Timer? _retry, _stall, _stable;
  static const _maxRetries=6;
  bool _valid(int generation)=>generation==_generation&&_wanted;
  void _cancelTimers(){_retry?.cancel();_retry=null;_stall?.cancel();_stall=null;_stable?.cancel();_stable=null;}
  void _scheduleRetry(int generation,String reason){
    if(!_valid(generation)||_opening||_retry!=null)return;
    _stall?.cancel();_stall=null;_stable?.cancel();_stable=null;
    if(_attempt>=_maxRetries){
      _wanted=false;_recovering=false;_failure='Stream unavailable: '+reason;
      unawaited(player.stop().catchError((Object _){}));
      playbackState.add(playbackState.value.copyWith(processingState:AudioProcessingState.error,errorMessage:'Stream unavailable: '+reason,playing:false));
      return;
    }
    final delay=[1,2,4,8,15,30][_attempt++];
    _recovering=true;
    print('WaveDrive: reconnect $_attempt/$_maxRetries in ${delay}s: $reason');
    _broadcast();
    _retry=Timer(Duration(seconds:delay),(){
      _retry=null;
      final s=current;
      if(_valid(generation)&&s!=null)unawaited(_connect(s,generation));
    });
  }
  void _observe(PlayerState state){
    _broadcast();
    if(!_wanted||_opening||_recovering)return;
    if(!state.playing){_stall?.cancel();_stall=null;_stable?.cancel();_stable=null;return;}
    final generation=_generation;
    if(state.processingState==ProcessingState.completed){
      _scheduleRetry(generation,'Stream ended');
      return;
    }
    if(state.playing&&(state.processingState==ProcessingState.buffering||state.processingState==ProcessingState.loading||state.processingState==ProcessingState.idle)){
      _stable?.cancel();_stable=null;
      _stall??=Timer(const Duration(seconds:15),(){_stall=null;_scheduleRetry(generation,'Buffering timeout');});
    }else{
      _stall?.cancel();_stall=null;
    }
    if(state.playing&&state.processingState==ProcessingState.ready){
      _stable??=Timer(const Duration(seconds:60),(){_stable=null;if(_valid(generation))_attempt=0;});
    }else{_stable?.cancel();_stable=null;}
  }
  StreamSubscription<IcyMetadata?>? _icySub;
  final nowPlaying=BehaviorSubject<String?>.seeded(null);
  final sleepDeadline=BehaviorSubject<DateTime?>.seeded(null);
  Timer? _sleepTimer;
  void setSleepTimer(Duration? duration){
    _sleepTimer?.cancel();_sleepTimer=null;
    if(duration==null||duration<=Duration.zero){sleepDeadline.add(null);return;}
    sleepDeadline.add(DateTime.now().add(duration));
    _sleepTimer=Timer(duration,(){
      setSleepTimer(null);
      unawaited(stop());
    });
  }
  final historyChanged=BehaviorSubject<int>.seeded(0);
  final Uri? fallbackArt;
  RadioHandler({this.fallbackArt}){
    player.playbackEventStream.listen((_)=>_broadcast(),onError:(Object e,StackTrace st){
      if(!_opening)_scheduleRetry(_generation,e.toString());
    });
    player.playerStateStream.listen(_observe);
  }
  void _broadcast(){
    final active=_failure==null&&_wanted&&(_opening||_recovering||player.playing);
    final processing=_failure!=null?AudioProcessingState.error:(_wanted&&(_opening||_recovering||player.processingState==ProcessingState.idle))?AudioProcessingState.buffering:const {ProcessingState.idle:AudioProcessingState.idle,ProcessingState.loading:AudioProcessingState.loading,ProcessingState.buffering:AudioProcessingState.buffering,ProcessingState.ready:AudioProcessingState.ready,ProcessingState.completed:AudioProcessingState.completed}[player.processingState]!;
    playbackState.add(PlaybackState(
      controls:[MediaControl.skipToPrevious,active?MediaControl.pause:MediaControl.play,MediaControl.skipToNext,MediaControl.stop],
      androidCompactActionIndices:const [0,1,2],
      systemActions:const {MediaAction.playFromMediaId,MediaAction.playFromSearch,MediaAction.playPause},
      errorMessage:_failure,
      processingState:processing,
      playing:active,updatePosition:player.position,bufferedPosition:player.bufferedPosition,speed:player.speed));
  }
  Uri? stationArt(Station s){
    final uri=Uri.tryParse(s.logo.trim());
    return uri!=null&&(uri.scheme=='http'||uri.scheme=='https')&&uri.host.isNotEmpty?uri:fallbackArt;
  }
  MediaItem item(Station s)=>MediaItem(id:s.id,title:s.name,album:s.country,artUri:stationArt(s),extras:{'url':s.url,'country':s.country,'logo':s.logo,'stationName':s.name});
  Station station(MediaItem m)=>Station(m.id,m.extras?['stationName'] as String? ?? m.title,m.extras?['url'] as String? ?? '',m.extras?['country'] as String? ?? '',m.extras?['logo'] as String? ?? '');
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
    _cancelTimers();_wanted=true;_attempt=0;_failure=null;_recovering=false;_opening=true;
    _active=list.isEmpty?[s]:List.of(list);
    current=s;nowPlaying.add(null);mediaItem.add(item(s));
    await _connect(s,generation);
    if(!_valid(generation))return;
    try{
      final p=await SharedPreferences.getInstance();
      final recent=[s,...(await stored('recent')).where((x)=>x.id!=s.id)].take(50);
      if(!_valid(generation))return;
      await p.setString('recent',jsonEncode(recent.map((x)=>x.toJson()).toList()));
      refreshChildren('recent');
      historyChanged.add(historyChanged.value+1);
    }catch(e){print('WaveDrive: history update failed: $e');}
  }
  Future<void> _connect(Station s,int generation) async {
    if(!_valid(generation))return;
    _opening=true;_recovering=true;_broadcast();
    try{
      await _icySub?.cancel();_icySub=null;
      if(!_valid(generation))return;
      await player.stop();
      if(!_valid(generation))return;
      await player.setUrl(s.url).timeout(const Duration(seconds:20));
      if(!_valid(generation))return;
      _icySub=player.icyMetadataStream.listen((metadata){
        if(!_valid(generation))return;
        final raw=metadata?.info?.title?.trim();
        final title=raw==null||raw.isEmpty?null:raw;
        if(nowPlaying.value==title)return;
        nowPlaying.add(title);
        final base=item(s);
        mediaItem.add(title==null?base:base.copyWith(title:title,artist:s.name,album:s.country));
      });
      // Keep the session in buffering until play has been requested. Never
      // advertise idle during a reconnect, since idle stops AudioService.
      final playback=player.play();
      _opening=false;_recovering=false;
      unawaited(playback.catchError((Object e){_scheduleRetry(generation,e.toString());}));
      _observe(player.playerState);
    }catch(e){
      if(_valid(generation)){_opening=false;_scheduleRetry(generation,e.toString());}
    }finally{
      if(generation==_generation)_opening=false;
    }
  }
  @override Future<void> play() async {
    final s=current;if(s==null)return;
    if(_wanted&&(_opening||_recovering||player.playing))return;
    _cancelTimers();_wanted=true;_attempt=0;_failure=null;
    if(player.processingState==ProcessingState.idle||player.processingState==ProcessingState.completed){
      await _connect(s,++_generation);
    }else{
      final generation=_generation;
      unawaited(player.play().catchError((Object e){_scheduleRetry(generation,e.toString());}));
    }
  }
  @override Future<void> pause() async {
    _wanted=false;_cancelTimers();_recovering=false;
    if(_opening){++_generation;_opening=false;await player.stop();}else{await player.pause();}
    _broadcast();
  }
  @override Future<void> stop() async {
    setSleepTimer(null);
    ++_generation;_wanted=false;_opening=false;_recovering=false;_failure=null;_cancelTimers();
    await _icySub?.cancel();_icySub=null;
    await player.stop();await super.stop();
  }
  Future<void> _skip(int delta) async {if(_active.isEmpty)return;final i=_active.indexWhere((s)=>s.id==current?.id);await select(_active[(i+delta+_active.length)%_active.length],_active);}
  @override Future<void> skipToNext()=>_skip(1);
  @override Future<void> skipToPrevious()=>_skip(-1);
  @override Future<void> playFromSearch(String query,[Map<String,dynamic>? extras]) async {final list=await api.search(query,'');if(list.isNotEmpty)await select(list.first,list);}
  @override Future<List<MediaItem>> search(String query,[Map<String,dynamic>? extras]) async => (await api.search(query,'')).map(item).toList();
}
