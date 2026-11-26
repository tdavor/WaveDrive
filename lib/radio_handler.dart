import 'dart:async';
import 'dart:convert';
import 'package:rxdart/rxdart.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'radio_api.dart';
import 'car_artwork.dart';

class RadioHandler extends BaseAudioHandler {
  final _children=<String,BehaviorSubject<Map<String,dynamic>>>{};
  BehaviorSubject<Map<String,dynamic>> _subject(String id)=>_children.putIfAbsent(id,()=>BehaviorSubject.seeded(<String,dynamic>{}));
  @override ValueStream<Map<String,dynamic>> subscribeToChildren(String parentMediaId)=>_subject(parentMediaId);
  void refreshChildren(String id)=>_subject(id).add(<String,dynamic>{});
  final player=AudioPlayer(audioLoadConfiguration:const AudioLoadConfiguration(androidLoadControl:AndroidLoadControl(minBufferDuration:Duration(seconds:30),maxBufferDuration:Duration(seconds:60),bufferForPlaybackDuration:Duration(seconds:2),bufferForPlaybackAfterRebufferDuration:Duration(seconds:4))));
  final api=RadioApi();
  List<Station> _active=[];
  final Map<String,Station> _browseStations={};
  final Map<String,List<Station>> _browseLists={};
  DateTime? _popularFetched;
  List<MediaItem> _remember(String group,List<Station> list){
    final limited=list.take(100).toList();
    _browseLists[group]=limited;
    for(final s in limited){_browseStations[s.id]=s;}
    unawaited(_prepareBrowseArtwork(group,limited));
    return limited.map(item).toList();
  }
  Future<void> _prepareBrowseArtwork(String group,List<Station> stations) async {
    final results=await Future.wait(stations.map(artwork.prepare));
    if(results.any((changed)=>changed))refreshChildren(group);
  }
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
  late final CarArtwork artwork=CarArtwork(fallbackArt);
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
  MediaItem item(Station s)=>MediaItem(id:s.id,title:s.name,album:s.country,displayTitle:s.name,displaySubtitle:s.country,artUri:artwork.uri(s),extras:{'url':s.url,'country':s.country,'logo':s.logo,'stationName':s.name});
  MediaItem _playingItem(Station s){
    final base=item(s);
    final song=nowPlaying.value;
    final path=artwork.localPath(s);
    return base.copyWith(title:song??s.name,artist:song==null?null:s.name,displayTitle:song??s.name,displaySubtitle:song==null?s.country:s.name,extras:{...base.extras!,if(path!=null)'artCacheFile':path});
  }
  Future<void> _preparePlayingArtwork(Station s,int generation) async {
    if(await artwork.prepare(s)&&_valid(generation)&&current?.id==s.id){
      mediaItem.add(_playingItem(s));
    }
  }
  static const _countries=<String,List<String>>{
    'SE':['Sweden','Sverige','Švedska'],'HR':['Croatia','Kroatien','Hrvatska'],'GB':['United Kingdom','Storbritannien','Ujedinjeno Kraljevstvo'],'DE':['Germany','Tyskland','Njemačka'],'US':['USA','USA','SAD'],'IT':['Italy','Italien','Italija'],'FR':['France','Frankrike','Francuska'],'NO':['Norway','Norge','Norveška'],'DK':['Denmark','Danmark','Danska'],'FI':['Finland','Finland','Finska'],'BA':['Bosnia and Herzegovina','Bosnien och Hercegovina','Bosna i Hercegovina'],'RS':['Serbia','Serbien','Srbija'],'SI':['Slovenia','Slovenien','Slovenija'],'ES':['Spain','Spanien','Španjolska'],'PL':['Poland','Polen','Poljska'],'AU':['Australia','Australien','Australija'],'CA':['Canada','Kanada','Kanada'],'JP':['Japan','Japan','Japan'],'BR':['Brazil','Brasilien','Brazil'],'IN':['India','Indien','Indija'],
  };
  static const _genres=<String,List<String>>{
    'news':['News','Nyheter','Vijesti'],'pop':['Pop','Pop','Pop'],'rock':['Rock','Rock','Rock'],'dance':['Dance','Dans','Dance'],'jazz':['Jazz','Jazz','Jazz'],'classical':['Classical','Klassiskt','Klasična'],'80s':['80s','80-tal','80-e'],'90s':['90s','90-tal','90-e'],'local':['Local','Lokalt','Lokalno'],
  };
  MediaItem _folder(String id,String title)=>MediaItem(id:id,title:title,artUri:artwork.logo,playable:false);
  Station station(MediaItem m)=>Station(m.id,m.extras?['stationName'] as String? ?? m.title,m.extras?['url'] as String? ?? '',m.extras?['country'] as String? ?? '',m.extras?['logo'] as String? ?? '');
  Future<List<Station>> stored(String key) async {
    final p=await SharedPreferences.getInstance();await p.reload();
    return (jsonDecode(p.getString(key)??'[]') as List).map((j)=>Station.fromJson(Map<String,dynamic>.from(j))).toList();
  }
  @override Future<List<MediaItem>> getChildren(String parentMediaId,[Map<String,dynamic>? options]) async {
    if(parentMediaId==AudioService.browsableRootId||parentMediaId=='countries'||parentMediaId=='genres'){
      final p=await SharedPreferences.getInstance();await p.reload();
      final lang=p.getString('language')??'en';
      String tr(String en,String sv,String hr)=>lang=='sv'?sv:lang=='hr'?hr:en;
      if(parentMediaId=='countries'||parentMediaId=='genres'){
        final groups=parentMediaId=='countries'?_countries:_genres;
        final prefix=parentMediaId=='countries'?'country:':'genre:';
        return groups.entries.map((entry)=>_folder(prefix+entry.key,tr(entry.value[0],entry.value[1],entry.value[2]))).toList();
      }
      return [_folder('favorites',tr('Favorites','Favoriter','Omiljene')),_folder('recent',tr('Recent','Senaste','Nedavno')),_folder('popular',tr('Popular stations','Populära stationer','Popularne stanice')),_folder('countries',tr('Countries','Länder','Države')),_folder('genres',tr('Genres','Genrer','Žanrovi'))];
    }
    try{
      if(parentMediaId==AudioService.recentRootId)return _remember('recent',await stored('recent'));
      if(parentMediaId=='favorites'||parentMediaId=='recent')return _remember(parentMediaId,await stored(parentMediaId));
      if(parentMediaId=='popular'){
        if(_popularFetched!=null&&DateTime.now().difference(_popularFetched!)<const Duration(minutes:5))return _remember('popular',_browseLists['popular']??[]);
        final list=await api.search('','');_popularFetched=DateTime.now();return _remember('popular',list);
      }
      if(parentMediaId.startsWith('country:')||parentMediaId.startsWith('genre:')){
        final value=parentMediaId.substring(parentMediaId.indexOf(':')+1);
        final country=parentMediaId.startsWith('country:');
        if(!(country?_countries:_genres).containsKey(value))return [];
        final cached=_browseLists[parentMediaId];
        if(cached!=null)return _remember(parentMediaId,cached);
        return _remember(parentMediaId,await api.search('',country?value:'',tag:country?'':value));
      }
      return [];
    }catch(_){return (_browseLists[parentMediaId]??[]).map(item).toList();}
  }
  @override Future<MediaItem?> getMediaItem(String mediaId) async {
    if(current?.id==mediaId)return item(current!);
    final cached=_browseStations[mediaId];if(cached!=null)return item(cached);
    for(final key in ['favorites','recent','popular']){
      for(final m in await getChildren(key)){if(m.id==mediaId)return m;}
    }
    return null;
  }
  @override Future<void> playFromMediaId(String mediaId,[Map<String,dynamic>? extras]) async {
    final cached=_browseStations[mediaId];
    if(cached!=null){
      final list=_browseLists.values.firstWhere((list)=>list.any((s)=>s.id==mediaId),orElse:()=>[cached]);
      await select(cached,list);return;
    }
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
    current=s;nowPlaying.add(null);mediaItem.add(_playingItem(s));
    unawaited(_preparePlayingArtwork(s,generation));
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
        mediaItem.add(_playingItem(s));
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
    final s=current;
    if(s==null){
      try{final recent=await stored('recent');if(current==null&&recent.isNotEmpty)await select(recent.first,recent);}catch(e){print('WaveDrive: resume failed: $e');}
      return;
    }
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
  @override Future<List<MediaItem>> search(String query,[Map<String,dynamic>? extras]) async => _remember('search',await api.search(query,''));
}
