import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_session/audio_session.dart';
import 'radio_api.dart';

void main()=>runApp(const MaterialApp(debugShowCheckedModeBanner:false,home:RadioHome()));
class RadioHome extends StatefulWidget {
  const RadioHome({super.key});
  @override State<RadioHome> createState()=>_RadioHomeState();
}
class _RadioHomeState extends State<RadioHome> {
  final api=RadioApi(), player=AudioPlayer(), query=TextEditingController();
  List<Station> stations=[], favorites=[], recent=[];
  Station? current;
  String country='',lang='en',error='';
  int tab=0, request=0;
  bool loading=false;
  String tr(String en,String sv,String hr)=>lang=='sv'?sv:lang=='hr'?hr:en;
  @override void initState(){super.initState();init();}
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
    await p.setString('recent',jsonEncode(recent.map((s)=>s.toJson()).toList()));
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
      await player.setUrl(s.url);
      if(!mounted||current!=s)return;
      setState((){recent=[s,...recent.where((x)=>x.id!=s.id)].take(50).toList();});
      await save();
      await player.play();
    }catch(_){if(mounted&&current==s)setState(()=>error=tr('Stream unavailable','Strömmen är otillgänglig','Stream nije dostupan'));}
  }
  @override void dispose(){player.dispose();query.dispose();super.dispose();}
  @override Widget build(BuildContext context){
    final list=tab==1?favorites:tab==2?recent:stations;
    return Theme(data:ThemeData.dark(useMaterial3:true).copyWith(scaffoldBackgroundColor:const Color(0xff08152b),colorScheme:ColorScheme.fromSeed(seedColor:Colors.cyan,brightness:Brightness.dark)),child:Scaffold(
      appBar:AppBar(title:const Text('WaveDrive'),actions:[DropdownButton<String>(value:lang,items:const [DropdownMenuItem(value:'en',child:Text('EN')),DropdownMenuItem(value:'sv',child:Text('SV')),DropdownMenuItem(value:'hr',child:Text('HR'))],onChanged:(v){if(v!=null){setState(()=>lang=v);save();}})]),
      body:Column(children:[
        const Text('Your road. Your radio.'),
        if(tab==0) Padding(padding:const EdgeInsets.all(12),child:Column(children:[
          TextField(controller:query,onSubmitted:(_)=>search(),decoration:InputDecoration(hintText:tr('Search stations','Sök stationer','Traži stanice'),suffixIcon:IconButton(onPressed:search,icon:const Icon(Icons.search)))),
          DropdownButton<String>(value:country,isExpanded:true,items:[DropdownMenuItem(value:'',child:Text(tr('All countries','Alla länder','Sve države'))),...['SE','HR','GB','DE','US','FR','IT','NO','DK','FI','BA','RS','SI','ES','PL','AU','CA','JP','BR','IN'].map((c)=>DropdownMenuItem(value:c,child:Text(c)))],onChanged:(v){setState(()=>country=v??'');search();})
        ])),
        if(loading&&tab==0)const LinearProgressIndicator(),
        if(error.isNotEmpty)Text(error),
        Expanded(child:ListView.builder(itemCount:list.length,itemBuilder:(context,i){final s=list[i];final liked=favorites.any((x)=>x.id==s.id);return ListTile(leading:const Icon(Icons.radio),title:Text(s.name),subtitle:Text(s.country),onTap:()=>play(s),trailing:IconButton(icon:Icon(liked?Icons.favorite:Icons.favorite_border),onPressed:(){setState((){if(liked){favorites.removeWhere((x)=>x.id==s.id);}else{favorites.add(s);}});save();}));})),
        if(current!=null)ListTile(title:Text(current!.name),subtitle:const Text('LIVE'),trailing:StreamBuilder<PlayerState>(stream:player.playerStateStream,builder:(context,snapshot)=>IconButton(icon:Icon(snapshot.data?.playing==true?Icons.pause_circle:Icons.play_circle),onPressed:(){if(player.playing){player.pause();}else{player.play();}})))
      ]),
      bottomNavigationBar:NavigationBar(selectedIndex:tab,onDestinationSelected:(i)=>setState(()=>tab=i),destinations:[NavigationDestination(icon:const Icon(Icons.public),label:tr('Explore','Utforska','Istraži')),NavigationDestination(icon:const Icon(Icons.favorite),label:tr('Favorites','Favoriter','Omiljene')),NavigationDestination(icon:const Icon(Icons.history),label:tr('Recent','Senaste','Nedavno'))])
    ));
  }
}
