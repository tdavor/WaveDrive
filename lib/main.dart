import 'dart:convert';
import 'dart:async';
import 'radio_handler.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_session/audio_session.dart';
import 'radio_api.dart';

late RadioHandler radio;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  radio=await AudioService.init(builder:()=>RadioHandler(),config:const AudioServiceConfig(androidNotificationChannelId:'com.wavedrive.radio.playback',androidNotificationChannelName:'WaveDrive playback',androidNotificationOngoing:true));
  runApp(const MaterialApp(debugShowCheckedModeBanner:false,home:RadioHome()));
}
class RadioHome extends StatefulWidget {
  const RadioHome({super.key});
  @override State<RadioHome> createState()=>_RadioHomeState();
}
class _RadioHomeState extends State<RadioHome> {
  final api=RadioApi(), player=radio.player, query=TextEditingController();
  List<Station> stations=[], favorites=[], recent=[];
  Station? current;
  String country='',lang='en',error='';
  int tab=0, request=0;
  bool loading=false;
  String tr(String en,String sv,String hr)=>lang=='sv'?sv:lang=='hr'?hr:en;
  StreamSubscription<MediaItem?>? mediaSub;
  @override void initState(){super.initState();init();mediaSub=radio.mediaItem.listen((m){if(m!=null&&mounted){setState(()=>current=radio.station(m));radio.stored('recent').then((v){if(mounted)setState(()=>recent=v);});}});}
  Future<void> init() async {
    final session=await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    final p=await SharedPreferences.getInstance();
    List<Station> read(String key)=>(jsonDecode(p.getString(key)??'[]') as List).map((j)=>Station.fromJson(Map<String,dynamic>.from(j))).toList();
    if(!mounted)return;
    setState((){favorites=read('favorites');recent=read('recent');lang=p.getString('language')??'en';});
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
  @override void dispose(){mediaSub?.cancel();query.dispose();super.dispose();}
  static const panel=Color(0xff202937), cyan=Color(0xff38bdf8);
  Widget artwork(Station s,{double size=52})=>ClipRRect(borderRadius:BorderRadius.circular(12),child:Container(width:size,height:size,color:panel,child:s.logo.startsWith('http')?Image.network(s.logo,fit:BoxFit.contain,errorBuilder:(_,__,___)=>const Icon(Icons.radio,color:cyan)):const Icon(Icons.radio,color:cyan)));
  String flag(String code)=>code.isEmpty?'🌍':String.fromCharCodes(code.codeUnits.map((c)=>c+127397));
  final codes=['SE','HR','GB','DE','US','IT','FR','NO','DK','FI','BA','RS','SI','ES','PL','AU','CA','JP','BR','IN'];
  void chooseCountry(String c){setState((){country=c;tab=1;});search();}
  void skip(int delta){final list=tab==2?favorites:tab==3?recent:stations;if(list.isEmpty)return;final i=list.indexWhere((s)=>s.id==current?.id);play(list[(i+delta+list.length)%list.length]);}
  @override Widget build(BuildContext context){
    final list=tab==2?favorites:tab==3?recent:stations;
    final theme=ThemeData.dark(useMaterial3:true).copyWith(scaffoldBackgroundColor:const Color(0xff101520),colorScheme:ColorScheme.fromSeed(seedColor:cyan,brightness:Brightness.dark));
    return Theme(data:theme,child:Scaffold(
      appBar:AppBar(backgroundColor:const Color(0xff101520),title:const Row(children:[Icon(Icons.graphic_eq,color:cyan,size:30),SizedBox(width:8),Text('Wave',style:TextStyle(fontWeight:FontWeight.w800)),Text('Drive',style:TextStyle(color:cyan,fontWeight:FontWeight.w800))]),actions:[PopupMenuButton<String>(icon:const Icon(Icons.settings_outlined),onSelected:(v){setState(()=>lang=v);save();},itemBuilder:(_)=>const [PopupMenuItem(value:'en',child:Text('English')),PopupMenuItem(value:'sv',child:Text('Svenska')),PopupMenuItem(value:'hr',child:Text('Hrvatski'))])]),
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
          SliverList(delegate:SliverChildBuilderDelegate((context,i){final s=list[i];final liked=favorites.any((x)=>x.id==s.id);return Padding(padding:const EdgeInsets.symmetric(horizontal:8,vertical:3),child:ListTile(leading:artwork(s),title:Text(s.name,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w600)),subtitle:Text(s.country,maxLines:1),onTap:()=>play(s),trailing:Row(mainAxisSize:MainAxisSize.min,children:[IconButton(icon:Icon(liked?Icons.favorite:Icons.favorite_border,color:liked?cyan:Colors.white60),onPressed:(){setState((){if(liked){favorites.removeWhere((x)=>x.id==s.id);}else{favorites.add(s);}});save();}),IconButton(onPressed:()=>play(s),icon:const Icon(Icons.play_circle_outline,size:30))])));},childCount:list.length))
        ])),
        if(current!=null) Container(margin:const EdgeInsets.fromLTRB(12,4,12,8),padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:const Color(0xff26364a),borderRadius:BorderRadius.circular(18)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(tr('NOW PLAYING','SPELAS NU','TRENUTNO SVIRA'),style:const TextStyle(color:cyan,fontSize:10,letterSpacing:1.5)),
          const SizedBox(height:8),
          Row(children:[artwork(current!,size:48),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(current!.name,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.bold)),Text(current!.country,style:const TextStyle(color:Colors.white60,fontSize:12))])),IconButton(onPressed:()=>skip(-1),icon:const Icon(Icons.skip_previous)),StreamBuilder<PlayerState>(stream:player.playerStateStream,builder:(context,snapshot)=>IconButton(icon:Icon(snapshot.data?.playing==true?Icons.pause_circle_filled:Icons.play_circle_filled,color:cyan,size:36),onPressed:(){if(player.playing){radio.pause();}else{radio.play();}})),IconButton(onPressed:()=>skip(1),icon:const Icon(Icons.skip_next))])
        ]))
      ])),
      bottomNavigationBar:NavigationBar(backgroundColor:panel,indicatorColor:const Color(0xff29475a),selectedIndex:tab,onDestinationSelected:(i)=>setState(()=>tab=i),destinations:[NavigationDestination(icon:const Icon(Icons.home_outlined),label:tr('Home','Hem','Početna')),NavigationDestination(icon:const Icon(Icons.public),label:tr('Explore','Utforska','Istraži')),NavigationDestination(icon:const Icon(Icons.favorite_border),label:tr('Favorites','Favoriter','Omiljene')),NavigationDestination(icon:const Icon(Icons.history),label:tr('Recent','Senaste','Nedavno'))])
    ));
  }
}
