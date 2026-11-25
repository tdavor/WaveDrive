import 'dart:convert';
import 'dart:async';
import 'radio_handler.dart';
import 'update_service.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_session/audio_session.dart';
import 'radio_api.dart';

late RadioHandler radio;
const appVersion='1.0.0-alpha.6';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  radio=await AudioService.init(builder:()=>RadioHandler(),config:const AudioServiceConfig(androidNotificationChannelId:'com.wavedrive.radio.playback',androidNotificationChannelName:'WaveDrive playback',androidNotificationOngoing:false,androidStopForegroundOnPause:false));
  final session=await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());
  runApp(const MaterialApp(debugShowCheckedModeBanner:false,home:RadioHome()));
}
class RadioHome extends StatefulWidget {
  const RadioHome({super.key});
  @override State<RadioHome> createState()=>_RadioHomeState();
}
class _RadioHomeState extends State<RadioHome> {
  final api=RadioApi(), query=TextEditingController();
  List<Station> stations=[], favorites=[], recent=[];
  Station? current;
  String country='',lang='en',error='';
  int tab=0, request=0;
  bool loading=false;
  String tr(String en,String sv,String hr)=>lang=='sv'?sv:lang=='hr'?hr:en;
  StreamSubscription<MediaItem?>? mediaSub;
  StreamSubscription<int>? historySub;
  @override void initState(){super.initState();init();mediaSub=radio.mediaItem.listen((m){if(m!=null&&mounted){setState(()=>current=radio.station(m));}});historySub=radio.historyChanged.listen((_) {radio.stored('recent').then((v){if(mounted)setState(()=>recent=v);});});}
  bool checkingUpdate=false;
  final updater=UpdateService();
  Future<void> init() async {
    final p=await SharedPreferences.getInstance();
    List<Station> read(String key)=>(jsonDecode(p.getString(key)??'[]') as List).map((j)=>Station.fromJson(Map<String,dynamic>.from(j))).toList();
    if(!mounted)return;
    setState((){favorites=read('favorites');recent=read('recent');lang=p.getString('language')??'en';});
    unawaited(checkUpdate());
    await search();
  }
  Future<void> save() async {
    final p=await SharedPreferences.getInstance();
    await p.setString('favorites',jsonEncode(favorites.map((s)=>s.toJson()).toList()));
    radio.refreshChildren('favorites');
    await p.setString('language',lang);
  }
  Future<void> search() async {
    final id=++request;
    setState((){loading=true;error='';});
    try {final result=await api.search(query.text,country);if(mounted&&id==request)setState(()=>stations=result);}
    catch(_){if(mounted&&id==request)setState(()=>error=tr('Directory unavailable','Radiokatalogen är otillgänglig','Katalog nije dostupan'));}
    finally{if(mounted&&id==request)setState(()=>loading=false);}
  }
  Future<void> play(Station s) async {
    setState((){current=s;error='';});
    try {
      await radio.select(s,tab==2?favorites:tab==3?recent:stations);
      final updated=await radio.stored('recent');if(mounted)setState(()=>recent=updated);
    }catch(_){if(mounted&&current==s)setState(()=>error=tr('Stream unavailable','Strömmen är otillgänglig','Stream nije dostupan'));}
  }
  @override void dispose(){mediaSub?.cancel();historySub?.cancel();query.dispose();super.dispose();}
  static const panel=Color(0xff202937), cyan=Color(0xff38bdf8);
  Widget artwork(Station s,{double size=52})=>ClipRRect(borderRadius:BorderRadius.circular(12),child:Container(width:size,height:size,color:panel,child:s.logo.startsWith('http')?Image.network(s.logo,fit:BoxFit.contain,errorBuilder:(_,__,___)=>const Icon(Icons.radio,color:cyan)):const Icon(Icons.radio,color:cyan)));
  String flag(String code)=>code.isEmpty?'🌍':String.fromCharCodes(code.codeUnits.map((c)=>c+127397));
  final codes=['SE','HR','GB','DE','US','IT','FR','NO','DK','FI','BA','RS','SI','ES','PL','AU','CA','JP','BR','IN'];
  void chooseCountry(String c){setState((){country=c;tab=1;});search();}
  void skip(int delta){final list=tab==2?favorites:tab==3?recent:stations;if(list.isEmpty)return;final i=list.indexWhere((s)=>s.id==current?.id);play(list[(i+delta+list.length)%list.length]);}
  ThemeData get radioTheme=>ThemeData.dark(useMaterial3:true).copyWith(scaffoldBackgroundColor:const Color(0xff101520),colorScheme:ColorScheme.fromSeed(seedColor:cyan,brightness:Brightness.dark));
  Future<void> checkUpdate({bool manual=false}) async {
    if(checkingUpdate)return;
    checkingUpdate=true;
    try{
      final update=await updater.check(appVersion);
      if(!mounted)return;
      if(update==null){
        if(manual)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(tr('You have the latest version','Du har senaste versionen','Imate najnoviju verziju'))));
        return;
      }
      final ready=ValueNotifier<bool>(false);
      final message=ValueNotifier<String>(tr('Downloading update…','Hämtar uppdatering…','Preuzimanje nadogradnje…'));
      var installing=false;
      Future<void> install() async {
        if(installing)return;
        installing=true;
        try{
          final result=await updater.install();
          if(result=='permission')message.value=tr('Allow installation from WaveDrive, then return and tap Install.','Tillåt installation från WaveDrive, gå tillbaka och tryck Installera.','Dopustite instaliranje iz WaveDrivea, vratite se i pritisnite Instaliraj.');
        }catch(e){message.value=tr('Installation failed: ','Installation misslyckades: ','Instalacija nije uspjela: ')+e.toString();}
        finally{installing=false;}
      }
      final completed=ValueNotifier<bool>(false);
      final download=updater.download(update).then((_) async {
        ready.value=true;
        message.value=tr('Update downloaded. Android will ask for installation approval.','Uppdateringen är hämtad. Android ber om installationsgodkännande.','Nadogradnja je preuzeta. Android će zatražiti potvrdu instalacije.');
        if(mounted)await install();
      }).catchError((Object e){
        message.value=tr('Update download failed: ','Hämtning misslyckades: ','Preuzimanje nije uspjelo: ')+e.toString();
      });
      unawaited(download.whenComplete(()=>completed.value=true));
      await showDialog<void>(context:context,barrierDismissible:false,builder:(dialogContext){
        return Theme(data:radioTheme,child:ValueListenableBuilder<bool>(valueListenable:completed,builder:(_,done,__)=>PopScope(canPop:done,child:AlertDialog(
          title:Text(tr('New version','Ny version','Nova verzija')+' '+update.version),
          content:Column(mainAxisSize:MainAxisSize.min,children:[
            if(!done)const LinearProgressIndicator(),
            const SizedBox(height:12),
            ValueListenableBuilder<String>(valueListenable:message,builder:(_,v,__)=>Text(v))
          ]),
          actions:[
            if(done)TextButton(onPressed:()=>Navigator.of(dialogContext).pop(),child:Text(tr('Later','Senare','Kasnije'))),
            if(done&&ready.value)TextButton(onPressed:install,child:Text(tr('Install','Installera','Instaliraj')))
          ]
        ))));
      });
      await download;
      // Dialog values are collected after the route transition and installer callbacks.
    }catch(e){
      if(mounted&&manual)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(tr('Update check failed','Uppdateringskontrollen misslyckades','Provjera nadogradnje nije uspjela'))));
    }finally{checkingUpdate=false;}
  }
  void showAbout(){
    showDialog<void>(context:context,builder:(_)=>Theme(data:radioTheme,child:AlertDialog(
      title:Text(tr('About WaveDrive','Om WaveDrive','O WaveDriveu')),
      content:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
        Icon(Icons.graphic_eq,color:cyan,size:48),SizedBox(height:16),
        Text('WaveDrive',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),
        Text('Your road. Your radio.'),SizedBox(height:16),
        Text(tr('Version','Version','Verzija')+': '+appVersion),const SizedBox(height:8),Text(tr('Author','Författare','Autor')+': t.davor@gmail.com')
      ]),
      actions:[TextButton(onPressed:(){Navigator.of(context,rootNavigator:true).pop();unawaited(checkUpdate(manual:true));},child:Text(tr('Check for updates','Sök uppdateringar','Provjeri nadogradnje'))),TextButton(onPressed:()=>Navigator.of(context,rootNavigator:true).pop(),child:Text(tr('Close','Stäng','Zatvori')))]
    )));
  }
  void openPlayer([Station? selected]){
    if(selected!=null&&selected.id!=radio.current?.id){unawaited(play(selected));}
    else if(selected!=null&&!radio.playbackState.value.playing){unawaited(radio.play());}
    Navigator.of(context).push(MaterialPageRoute<void>(builder:(_)=>Theme(data:radioTheme,child:Scaffold(
      appBar:AppBar(backgroundColor:const Color(0xff101520),title:Text(tr('Now playing','Spelas nu','Trenutno svira'))),
      body:SafeArea(child:StreamBuilder<MediaItem?>(stream:radio.mediaItem,initialData:radio.mediaItem.value,builder:(context,snapshot){
        final m=snapshot.data;
        final s=m==null?selected??current:radio.station(m);
        if(s==null)return const SizedBox.shrink();
        final song=m!=null&&m.title!=s.name?m.title:null;
        return LayoutBuilder(builder:(context,limits)=>SingleChildScrollView(padding:const EdgeInsets.all(24),child:ConstrainedBox(constraints:BoxConstraints(minHeight:limits.maxHeight>48?limits.maxHeight-48:0),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[
          const Row(mainAxisAlignment:MainAxisAlignment.center,children:[Icon(Icons.circle,color:cyan,size:9),SizedBox(width:6),Text('LIVE',style:TextStyle(color:cyan,letterSpacing:2,fontWeight:FontWeight.bold))]),
          const SizedBox(height:28),
          artwork(s,size:(limits.maxWidth-48).clamp(100.0,300.0).toDouble()),
          const SizedBox(height:28),
          Text(s.name,textAlign:TextAlign.center,style:const TextStyle(fontSize:28,fontWeight:FontWeight.w800)),
          const SizedBox(height:6),Text(s.country,style:const TextStyle(color:Colors.white60)),
          const SizedBox(height:24),
          Text(song??tr('Song information unavailable','Låtinformation saknas','Podaci o pjesmi nisu dostupni'),textAlign:TextAlign.center,style:TextStyle(fontSize:20,color:song==null?Colors.white54:cyan,fontWeight:FontWeight.w600)),
          const SizedBox(height:28),
          StreamBuilder<PlaybackState>(stream:radio.playbackState,initialData:radio.playbackState.value,builder:(context,state){
            final playing=state.data?.playing??false;
            final processing=state.data?.processingState;
            return Column(children:[
              if(processing==AudioProcessingState.loading||processing==AudioProcessingState.buffering)...[const LinearProgressIndicator(),const SizedBox(height:8),Text(tr('Connecting…','Ansluter…','Povezivanje…'))],
              if(processing==AudioProcessingState.error)Text(tr('Stream unavailable','Strömmen är otillgänglig','Stream nije dostupan')),
              Row(mainAxisAlignment:MainAxisAlignment.center,children:[
                IconButton(onPressed:radio.skipToPrevious,icon:const Icon(Icons.skip_previous,size:40)),
                const SizedBox(width:12),
                IconButton(onPressed:playing?radio.pause:radio.play,icon:Icon(playing?Icons.pause_circle_filled:Icons.play_circle_filled,color:cyan,size:80)),
                const SizedBox(width:12),IconButton(onPressed:radio.skipToNext,icon:const Icon(Icons.skip_next,size:40))
              ])
            ]);
          })
        ]))));
      }))
    ))));
  }
  @override Widget build(BuildContext context){
    final list=tab==2?favorites:tab==3?recent:stations;
    final theme=radioTheme;
    return Theme(data:theme,child:Scaffold(
      appBar:AppBar(backgroundColor:const Color(0xff101520),title:const Row(children:[Icon(Icons.graphic_eq,color:cyan,size:30),SizedBox(width:8),Text('Wave',style:TextStyle(fontWeight:FontWeight.w800)),Text('Drive',style:TextStyle(color:cyan,fontWeight:FontWeight.w800))]),actions:[PopupMenuButton<String>(icon:const Icon(Icons.settings_outlined),onSelected:(v){if(v=='about'){showAbout();return;}setState(()=>lang=v);save();},itemBuilder:(_)=>[const PopupMenuItem(value:'en',child:Text('English')),const PopupMenuItem(value:'sv',child:Text('Svenska')),const PopupMenuItem(value:'hr',child:Text('Hrvatski')),PopupMenuItem(value:'about',child:Text(tr('About','Om','O aplikaciji')))])]),
      body:SafeArea(child:Column(children:[
        Expanded(child:CustomScrollView(slivers:[
          if(tab<2) SliverToBoxAdapter(child:Padding(padding:const EdgeInsets.fromLTRB(16,4,16,12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            const Text('Your road. Your radio.',style:TextStyle(color:Colors.white70)),
            const SizedBox(height:18),
            TextField(controller:query,onSubmitted:(_)=>search(),decoration:InputDecoration(filled:true,fillColor:panel,prefixIcon:const Icon(Icons.search),hintText:tr('Search radio stations...','Sök radiostationer...','Traži radio stanice...'),suffixIcon:IconButton(onPressed:search,icon:const Icon(Icons.arrow_forward)),border:OutlineInputBorder(borderRadius:BorderRadius.circular(16),borderSide:BorderSide.none))),
            const SizedBox(height:20),
            Row(children:[Expanded(child:Text(tr('Explore countries','Utforska länder','Istraži države'),style:const TextStyle(fontSize:18,fontWeight:FontWeight.bold))),TextButton(onPressed:(){setState(()=>tab=tab==0?1:0);},child:Text(tab==0?tr('View all','Visa alla','Prikaži sve'):tr('Less','Färre','Manje')))]),
            GridView.count(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),crossAxisCount:4,mainAxisSpacing:8,crossAxisSpacing:8,childAspectRatio:1.15,children:(tab==0?['SE','HR','GB','DE','US','IT','FR','']:['',...codes]).map((c)=>InkWell(borderRadius:BorderRadius.circular(14),onTap:()=>chooseCountry(c),child:Container(decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(14),border:Border.all(color:country==c?cyan:Colors.transparent)),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[Text(flag(c),style:const TextStyle(fontSize:26)),Text(c.isEmpty?tr('World','Världen','Svijet'):({'SE':tr('Sweden','Sverige','Švedska'),'HR':tr('Croatia','Kroatien','Hrvatska'),'GB':'UK','DE':tr('Germany','Tyskland','Njemačka'),'US':'USA','IT':tr('Italy','Italien','Italija'),'FR':tr('France','Frankrike','Francuska')}[c]??c),style:const TextStyle(fontSize:11),maxLines:1,overflow:TextOverflow.ellipsis)])))).toList()),
          ]))),
          SliverToBoxAdapter(child:Padding(padding:const EdgeInsets.fromLTRB(16,8,16,10),child:Text(tab==2?tr('Favorites','Favoriter','Omiljene'):tab==3?tr('Recently played','Senast spelade','Nedavno slušano'):tr('Popular stations','Populära stationer','Popularne stanice'),style:const TextStyle(fontSize:19,fontWeight:FontWeight.bold)))),
          if(loading&&tab<2)const SliverToBoxAdapter(child:LinearProgressIndicator()),
          if(error.isNotEmpty)SliverToBoxAdapter(child:Padding(padding:const EdgeInsets.all(16),child:Text(error))),
          SliverList(delegate:SliverChildBuilderDelegate((context,i){final s=list[i];final liked=favorites.any((x)=>x.id==s.id);return Padding(padding:const EdgeInsets.symmetric(horizontal:8,vertical:3),child:ListTile(leading:artwork(s),title:Text(s.name,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w600)),subtitle:Text(s.country,maxLines:1),onTap:()=>openPlayer(s),trailing:Row(mainAxisSize:MainAxisSize.min,children:[IconButton(icon:Icon(liked?Icons.favorite:Icons.favorite_border,color:liked?cyan:Colors.white60),onPressed:(){setState((){if(liked){favorites.removeWhere((x)=>x.id==s.id);}else{favorites.add(s);}});save();}),IconButton(onPressed:()=>openPlayer(s),icon:const Icon(Icons.play_circle_outline,size:30))])));},childCount:list.length))
        ])),
        if(current!=null) Container(margin:const EdgeInsets.fromLTRB(12,4,12,8),padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:const Color(0xff26364a),borderRadius:BorderRadius.circular(18)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(tr('NOW PLAYING','SPELAS NU','TRENUTNO SVIRA'),style:const TextStyle(color:cyan,fontSize:10,letterSpacing:1.5)),
          const SizedBox(height:8),
          Row(children:[InkWell(onTap:()=>openPlayer(),child:artwork(current!,size:48)),const SizedBox(width:10),Expanded(child:InkWell(onTap:()=>openPlayer(),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(current!.name,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.bold)),StreamBuilder<String?>(stream:radio.nowPlaying,initialData:radio.nowPlaying.value,builder:(context,snapshot)=>Text(snapshot.data??current!.country,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white60,fontSize:12)))]))),IconButton(onPressed:()=>skip(-1),icon:const Icon(Icons.skip_previous)),StreamBuilder<PlaybackState>(stream:radio.playbackState,initialData:radio.playbackState.value,builder:(context,snapshot)=>IconButton(icon:Icon(snapshot.data?.playing==true?Icons.pause_circle_filled:Icons.play_circle_filled,color:cyan,size:36),onPressed:(){if(radio.playbackState.value.playing){radio.pause();}else{radio.play();}})),IconButton(onPressed:()=>skip(1),icon:const Icon(Icons.skip_next))])
        ]))
      ])),
      bottomNavigationBar:NavigationBar(backgroundColor:panel,indicatorColor:const Color(0xff29475a),selectedIndex:tab,onDestinationSelected:(i)=>setState(()=>tab=i),destinations:[NavigationDestination(icon:const Icon(Icons.home_outlined),label:tr('Home','Hem','Početna')),NavigationDestination(icon:const Icon(Icons.public),label:tr('Explore','Utforska','Istraži')),NavigationDestination(icon:const Icon(Icons.favorite_border),label:tr('Favorites','Favoriter','Omiljene')),NavigationDestination(icon:const Icon(Icons.history),label:tr('Recent','Senaste','Nedavno'))])
    ));
  }
}
