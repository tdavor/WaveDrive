import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'radio_handler.dart';
import 'update_service.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audio_session/audio_session.dart';
import 'radio_api.dart';

late RadioHandler radio;
const appVersion='1.0.8';
const donationUrl='https://buymeacoffee.com/wjkrddbhyx';
const brandLogo='assets/branding/wavedrive.webp';

Future<Uri?> prepareBrandArtwork() async {
  try{
    final dir=await getApplicationSupportDirectory();
    final file=File('${dir.path}/wavedrive_brand.webp');
    final data=await rootBundle.load(brandLogo);
    await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes,data.lengthInBytes),flush:true);
    return file.uri;
  }catch(e){debugPrint('WaveDrive artwork: $e');return null;}
}
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final fallbackArt=await prepareBrandArtwork().timeout(const Duration(seconds:2),onTimeout:()=>null);
  radio=await AudioService.init(builder:()=>RadioHandler(fallbackArt:fallbackArt),config:const AudioServiceConfig(androidNotificationChannelId:'com.wavedrive.radio.media',androidNotificationChannelName:'WaveDrive media playback',androidNotificationIcon:'drawable/ic_wavedrive_notification',androidNotificationClickStartsActivity:true,androidNotificationOngoing:false,androidStopForegroundOnPause:false));
  final session=await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());
  runApp(const MaterialApp(debugShowCheckedModeBanner:false,home:WaveSplash()));
}
class WaveSplash extends StatefulWidget {
  const WaveSplash({super.key});
  @override State<WaveSplash> createState()=>_WaveSplashState();
}
class _WaveSplashState extends State<WaveSplash> {
  Timer? _timer;
  @override void initState(){
    super.initState();
    _timer=Timer(const Duration(milliseconds:1400),(){
      if(!mounted)return;
      Navigator.of(context).pushReplacement(PageRouteBuilder<void>(
        pageBuilder:(_,__,___)=>const RadioHome(),
        transitionDuration:const Duration(milliseconds:200),
        transitionsBuilder:(_,animation,__,child)=>FadeTransition(opacity:animation,child:child),
      ));
    });
  }
  @override void dispose(){_timer?.cancel();super.dispose();}
  @override Widget build(BuildContext context)=>const AnnotatedRegion<SystemUiOverlayStyle>(
    value:SystemUiOverlayStyle(statusBarColor:Colors.black,systemNavigationBarColor:Colors.black,statusBarIconBrightness:Brightness.light,systemNavigationBarIconBrightness:Brightness.light),
    child:Scaffold(
      backgroundColor:Colors.black,
      body:SizedBox.expand(child:Image(image:AssetImage(brandLogo),fit:BoxFit.contain)),
    ),
  );
}
class RadioHome extends StatefulWidget {
  const RadioHome({super.key});
  @override State<RadioHome> createState()=>_RadioHomeState();
}
class _RadioHomeState extends State<RadioHome> with WidgetsBindingObserver {
  final api=RadioApi(), query=TextEditingController();
  List<Station> stations=[], favorites=[], recent=[];
  Station? current;
  String country='',lang='en',error='';
  int tab=0, request=0;
  bool loading=false;
  String tr(String en,String sv,String hr)=>lang=='sv'?sv:lang=='hr'?hr:en;
  StreamSubscription<MediaItem?>? mediaSub;
  StreamSubscription<int>? historySub;
  @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);init();mediaSub=radio.mediaItem.listen((m){if(m!=null&&mounted){setState(()=>current=radio.station(m));}});historySub=radio.historyChanged.listen((_) {radio.stored('recent').then((v){if(mounted)setState(()=>recent=v);});});}
  bool _preferencesReady=false,_phoneStartupDone=false;
  bool autoResume=false;
  @override void didChangeAppLifecycleState(AppLifecycleState state){
    if(state==AppLifecycleState.resumed)unawaited(_phoneStartup());
  }
  Future<void> _phoneStartup() async {
    if(!mounted||!_preferencesReady||_phoneStartupDone||WidgetsBinding.instance.lifecycleState!=AppLifecycleState.resumed)return;
    _phoneStartupDone=true;
    if(autoResume&&recent.isNotEmpty&&radio.current==null){unawaited(radio.select(recent.first,List<Station>.of(recent)));}
    unawaited(startupChecks());
    await search();
  }
  bool checkingUpdate=false;
  final updater=UpdateService();
  Future<void> init() async {
    final p=await SharedPreferences.getInstance();
    List<Station> read(String key)=>(jsonDecode(p.getString(key)??'[]') as List).map((j)=>Station.fromJson(Map<String,dynamic>.from(j))).toList();
    if(!mounted)return;
    setState((){favorites=read('favorites');recent=read('recent');lang=p.getString('language')??'en';autoResume=p.getBool('auto_resume')??false;});
    _preferencesReady=true;
    await _phoneStartup();
  }
  static const _batteryChannel=MethodChannel('wavedrive/update');
  bool _batteryDialogOpen=false;
  Future<void> startupChecks() async {
    await checkUpdate();
    if(!mounted||WidgetsBinding.instance.lifecycleState!=AppLifecycleState.resumed)return;
    await batterySetup();
  }
  Future<void> batterySetup({bool manual=false}) async {
    if(_batteryDialogOpen||!mounted)return;
    _batteryDialogOpen=true;
    try{
      final prefs=await SharedPreferences.getInstance();
      if(!manual&&(prefs.getBool('battery_help_seen')??false))return;
      final status=await _batteryChannel.invokeMapMethod<String,dynamic>('batteryStatus');
      if(!mounted||status==null)return;
      final exempt=status['exempt']==true;
      final restricted=status['restricted']==true;
      if(!manual&&exempt&&!restricted){await prefs.setBool('battery_help_seen',true);return;}
      if(WidgetsBinding.instance.lifecycleState!=AppLifecycleState.resumed)return;
      final open=await showDialog<bool>(context:context,builder:(ctx)=>Theme(data:radioTheme,child:AlertDialog(
        title:Text(tr('Background playback','Uppspelning i bakgrunden','Reprodukcija u pozadini')),
        content:Text(exempt&&!restricted
          ?tr('Android currently reports no battery restriction for WaveDrive. You can review your battery settings.','Android rapporterar inga batteribegränsningar för WaveDrive. Du kan kontrollera inställningarna.','Android trenutačno ne prijavljuje ograničenja baterije za WaveDrive. Postavke možete provjeriti.')
          :tr('If radio stops when the screen is off, open app settings and allow background battery usage. Choose Unrestricted if available. This is optional and may increase battery use.','Om radion stannar när skärmen är släckt, öppna appinställningarna och tillåt batterianvändning i bakgrunden. Välj Obegränsad om alternativet finns. Det är frivilligt och kan öka batteriförbrukningen.','Ako radio prestaje svirati kada je zaslon ugašen, otvorite postavke aplikacije i dopustite korištenje baterije u pozadini. Odaberite Neograničeno ako je dostupno. Ovo nije obavezno i može povećati potrošnju baterije.')),
        actions:[
          TextButton(onPressed:()=>Navigator.of(ctx).pop(false),child:Text(tr('Later','Senare','Kasnije'))),
          TextButton(onPressed:()=>Navigator.of(ctx).pop(true),child:Text(tr('Open settings','Öppna inställningar','Otvori postavke')))
        ]
      )));
      await prefs.setBool('battery_help_seen',true);
      if(open==true&&mounted)await _batteryChannel.invokeMethod<bool>('batterySettings');
    }catch(e){debugPrint('WaveDrive battery setup: $e');}
    finally{_batteryDialogOpen=false;}
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
      await radio.select(s,tab==1?favorites:tab==2?recent:stations);
      final updated=await radio.stored('recent');if(mounted)setState(()=>recent=updated);
    }catch(_){if(mounted&&current==s)setState(()=>error=tr('Stream unavailable','Strömmen är otillgänglig','Stream nije dostupan'));}
  }
  @override void dispose(){WidgetsBinding.instance.removeObserver(this);mediaSub?.cancel();historySub?.cancel();query.dispose();super.dispose();}
  static const panel=Color(0xff202937), cyan=Color(0xff38bdf8);
  Widget artwork(Station s,{double size=52})=>ClipRRect(borderRadius:BorderRadius.circular(12),child:Container(width:size,height:size,color:panel,child:s.logo.startsWith('http')?Image.network(s.logo,fit:BoxFit.contain,errorBuilder:(_,__,___)=>Image.asset(brandLogo,fit:BoxFit.contain)):Image.asset(brandLogo,fit:BoxFit.contain)));
  String flag(String code)=>code.isEmpty?'🌍':String.fromCharCodes(code.codeUnits.map((c)=>c+127397));
  final codes=['SE','HR','GB','DE','US','IT','FR','NO','DK','FI','BA','RS','SI','ES','PL','AU','CA','JP','BR','IN'];
  String countryName(String code){
    final names=<String,List<String>>{
      'SE':['Sweden','Sverige','Švedska'],'HR':['Croatia','Kroatien','Hrvatska'],
      'GB':['United Kingdom','Storbritannien','Ujedinjeno Kraljevstvo'],'DE':['Germany','Tyskland','Njemačka'],
      'US':['United States','USA','SAD'],'IT':['Italy','Italien','Italija'],'FR':['France','Frankrike','Francuska'],
      'NO':['Norway','Norge','Norveška'],'DK':['Denmark','Danmark','Danska'],'FI':['Finland','Finland','Finska'],
      'BA':['Bosnia and Herzegovina','Bosnien och Hercegovina','Bosna i Hercegovina'],
      'RS':['Serbia','Serbien','Srbija'],'SI':['Slovenia','Slovenien','Slovenija'],'ES':['Spain','Spanien','Španjolska'],
      'PL':['Poland','Polen','Poljska'],'AU':['Australia','Australien','Australija'],'CA':['Canada','Kanada','Kanada'],
      'JP':['Japan','Japan','Japan'],'BR':['Brazil','Brasilien','Brazil'],'IN':['India','Indien','Indija'],
    };
    final name=names[code];return name==null?code:tr(name[0],name[1],name[2]);
  }
  void chooseCountry(String c){setState(()=>country=c);search();}
  void skip(int delta){unawaited(delta<0?radio.skipToPrevious():radio.skipToNext());}
  ThemeData get radioTheme=>ThemeData.dark(useMaterial3:true).copyWith(scaffoldBackgroundColor:const Color(0xff101520),colorScheme:ColorScheme.fromSeed(seedColor:cyan,brightness:Brightness.dark));
  Future<void> checkUpdate({bool manual=false}) async {
    if(checkingUpdate)return;
    checkingUpdate=true;
    try{
      final update=await updater.check(appVersion);
      if(!mounted||WidgetsBinding.instance.lifecycleState!=AppLifecycleState.resumed)return;
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
        if(mounted&&WidgetsBinding.instance.lifecycleState==AppLifecycleState.resumed)await install();
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
  Future<void> showSettings() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder:(routeContext)=>Theme(data:radioTheme,child:StatefulBuilder(builder:(ctx,refresh){
      return Scaffold(
        appBar:AppBar(title:Text(tr('Settings','Inställningar','Postavke'))),
        body:SafeArea(child:ListView(padding:const EdgeInsets.all(16),children:[
          Text(tr('Playback','Uppspelning','Reprodukcija'),style:const TextStyle(color:cyan,fontWeight:FontWeight.bold)),
          StreamBuilder<DateTime?>(stream:radio.sleepDeadline,initialData:radio.sleepDeadline.value,builder:(context,snapshot){
            final deadline=snapshot.data;
            return ListTile(
              leading:const Icon(Icons.bedtime_outlined,color:cyan),
              title:Text(tr('Sleep timer','Insomningstimer','Timer za spavanje')),
              subtitle:deadline==null?Text(tr('Off','Av','Isključeno')):StreamBuilder<int>(
                stream:Stream.periodic(const Duration(seconds:1),(i)=>i),
                builder:(context,_) {
                  final seconds=deadline.difference(DateTime.now()).inSeconds.clamp(0,86400).toInt();
                  final min=seconds~/60;final sec=seconds%60;
                  return Text('$min:${sec.toString().padLeft(2,'0')}');
                }),
              trailing:const Icon(Icons.chevron_right),
              onTap:() async {
                final selected=await showDialog<int>(context:ctx,builder:(dialogContext)=>Theme(data:radioTheme,child:SimpleDialog(
                  title:Text(tr('Stop radio after','Stoppa radion efter','Zaustavi radio nakon')),
                  children:[for(final minutes in [15,30,60,90])SimpleDialogOption(onPressed:()=>Navigator.pop(dialogContext,minutes),child:Text('$minutes min')),
                    SimpleDialogOption(onPressed:()=>Navigator.pop(dialogContext,0),child:Text(tr('Turn off timer','Stäng av timer','Isključi timer')))]
                )));
                if(selected!=null)radio.setSleepTimer(selected==0?null:Duration(minutes:selected));
              },
            );
          }),
          SwitchListTile(
            secondary:const Icon(Icons.play_circle_outline,color:cyan),
            title:Text(tr('Auto resume','Automatisk återupptagning','Automatski nastavak')),
            subtitle:Text(tr('Play the last station when WaveDrive starts','Spela senaste stationen när WaveDrive startar','Pokreni posljednju stanicu pri otvaranju WaveDrivea')),
            value:autoResume,
            onChanged:(value) async {
              if(!mounted)return;
              setState(()=>autoResume=value);refresh((){});
              final prefs=await SharedPreferences.getInstance();await prefs.setBool('auto_resume',value);
            },
          ),
          const Divider(),
          Text(tr('General','Allmänt','Općenito'),style:const TextStyle(color:cyan,fontWeight:FontWeight.bold)),
          ListTile(leading:const Icon(Icons.language,color:cyan),title:Text(tr('Language','Språk','Jezik')),trailing:DropdownButton<String>(
            value:lang,items:const [DropdownMenuItem(value:'en',child:Text('English')),DropdownMenuItem(value:'sv',child:Text('Svenska')),DropdownMenuItem(value:'hr',child:Text('Hrvatski'))],
            onChanged:(value){if(value==null||!mounted)return;setState(()=>lang=value);refresh((){});unawaited(save());},
          )),
          ListTile(leading:const Icon(Icons.battery_charging_full,color:cyan),title:Text(tr('Battery settings','Batteriinställningar','Postavke baterije')),onTap:(){Navigator.pop(routeContext);unawaited(batterySetup(manual:true));}),
          ListTile(leading:const Icon(Icons.system_update,color:cyan),title:Text(tr('Check for updates','Sök uppdateringar','Provjeri nadogradnje')),onTap:(){Navigator.pop(routeContext);unawaited(checkUpdate(manual:true));}),
          const Divider(),
          Text(tr('Support','Stöd','Podrška'),style:const TextStyle(color:cyan,fontWeight:FontWeight.bold)),
          ListTile(
            leading:const Icon(Icons.coffee_outlined,color:cyan),
            title:const Text('Buy Me a Coffee'),
            subtitle:Text(tr('Support WaveDrive voluntarily','Stöd WaveDrive frivilligt','Dobrovoljno podrži WaveDrive')),
            trailing:const Icon(Icons.open_in_new),
            onTap:() async {
              try{if(await launchUrl(Uri.parse(donationUrl),mode:LaunchMode.externalApplication))return;}catch(_){}
              if(ctx.mounted)ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content:Text(tr('Could not open link','Kunde inte öppna länken','Poveznica se ne može otvoriti'))));
            },
          ),
          ListTile(leading:const Icon(Icons.info_outline,color:cyan),title:Text(tr('About','Om','O aplikaciji')),onTap:(){Navigator.pop(routeContext);showAbout();})
        ])),
      );
    }))));
  }
  void showAbout(){
    showDialog<void>(context:context,builder:(_)=>Theme(data:radioTheme,child:AlertDialog(
      title:Text(tr('About WaveDrive','Om WaveDrive','O WaveDriveu')),
      content:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
        ClipRRect(borderRadius:BorderRadius.circular(14),child:Image.asset(brandLogo,width:96,height:96,fit:BoxFit.contain)),const SizedBox(height:16),
        Text('WaveDrive',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold)),
        Text('Your road. Your radio.'),SizedBox(height:16),
        Text(tr('Version','Version','Verzija')+': '+appVersion),const SizedBox(height:8),Text(tr('Author','Författare','Autor')+': t.davor@gmail.com')
      ]),
      actions:[TextButton(onPressed:(){Navigator.of(context,rootNavigator:true).pop();unawaited(batterySetup(manual:true));},child:Text(tr('Battery settings','Batteriinställningar','Postavke baterije'))),TextButton(onPressed:(){Navigator.of(context,rootNavigator:true).pop();unawaited(checkUpdate(manual:true));},child:Text(tr('Check for updates','Sök uppdateringar','Provjeri nadogradnje'))),TextButton(onPressed:()=>Navigator.of(context,rootNavigator:true).pop(),child:Text(tr('Close','Stäng','Zatvori')))]
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
    final list=tab==1?favorites:tab==2?recent:stations;
    final theme=radioTheme;
    return Theme(data:theme,child:Scaffold(
      appBar:AppBar(backgroundColor:const Color(0xff101520),title:Row(children:[ClipRRect(borderRadius:BorderRadius.circular(8),child:Image.asset(brandLogo,width:38,height:38,fit:BoxFit.contain)),const SizedBox(width:8),const Text('Wave',style:TextStyle(fontWeight:FontWeight.w800)),const Text('Drive',style:TextStyle(color:cyan,fontWeight:FontWeight.w800))]),actions:[IconButton(icon:const Icon(Icons.settings_outlined),tooltip:tr('Settings','Inställningar','Postavke'),onPressed:showSettings)]),
      body:SafeArea(child:Column(children:[
        Expanded(child:CustomScrollView(slivers:[
          if(tab==0) SliverToBoxAdapter(child:Padding(padding:const EdgeInsets.fromLTRB(16,4,16,12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            const Text('Your road. Your radio.',style:TextStyle(color:Colors.white70)),
            const SizedBox(height:18),
            TextField(controller:query,textInputAction:TextInputAction.search,onSubmitted:(_)=>search(),decoration:InputDecoration(filled:true,fillColor:panel,prefixIcon:const Icon(Icons.search),hintText:tr('Search radio stations...','Sök radiostationer...','Traži radio stanice...'),suffixIcon:IconButton(onPressed:search,icon:const Icon(Icons.arrow_forward)),border:OutlineInputBorder(borderRadius:BorderRadius.circular(16),borderSide:BorderSide.none))),
            const SizedBox(height:8),
            Row(children:[
              const Icon(Icons.public,color:Colors.white60,size:18),
              const SizedBox(width:8),
              Expanded(child:DropdownButtonHideUnderline(child:DropdownButton<String>(
                value:country,isExpanded:true,
                items:['',...codes].map((code)=>DropdownMenuItem(value:code,child:Text(code.isEmpty?tr('All countries','Alla länder','Sve države'):'${flag(code)}  ${countryName(code)}',overflow:TextOverflow.ellipsis))).toList(),
                onChanged:(value){if(value!=null&&value!=country)chooseCountry(value);},
              ))),
            ]),
          ]))),
          SliverToBoxAdapter(child:Padding(padding:const EdgeInsets.fromLTRB(16,8,16,10),child:Text(tab==1?tr('Favorites','Favoriter','Omiljene'):tab==2?tr('Recently played','Senast spelade','Nedavno slušano'):(query.text.trim().isEmpty&&country.isEmpty?tr('Popular stations','Populära stationer','Popularne stanice'):tr('Radio stations','Radiostationer','Radio stanice')),style:const TextStyle(fontSize:19,fontWeight:FontWeight.bold)))),
          if(loading&&tab==0)const SliverToBoxAdapter(child:LinearProgressIndicator()),
          if(tab==0&&!loading&&error.isEmpty&&stations.isEmpty)SliverToBoxAdapter(child:Padding(padding:const EdgeInsets.all(16),child:Text(tr('No stations found','Inga stationer hittades','Nema pronađenih stanica')))),
          if(error.isNotEmpty)SliverToBoxAdapter(child:Padding(padding:const EdgeInsets.all(16),child:Text(error))),
          SliverList(delegate:SliverChildBuilderDelegate((context,i){final s=list[i];final liked=favorites.any((x)=>x.id==s.id);return Padding(padding:const EdgeInsets.symmetric(horizontal:8,vertical:3),child:ListTile(leading:artwork(s),title:Text(s.name,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.w600)),subtitle:Text(s.country,maxLines:1),onTap:()=>openPlayer(s),trailing:Row(mainAxisSize:MainAxisSize.min,children:[IconButton(icon:Icon(liked?Icons.favorite:Icons.favorite_border,color:liked?cyan:Colors.white60),onPressed:(){setState((){if(liked){favorites.removeWhere((x)=>x.id==s.id);}else{favorites.add(s);}});save();}),IconButton(onPressed:()=>openPlayer(s),icon:const Icon(Icons.play_circle_outline,size:30))])));},childCount:list.length))
        ])),
        if(current!=null) Container(margin:const EdgeInsets.fromLTRB(12,4,12,8),padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:const Color(0xff26364a),borderRadius:BorderRadius.circular(18)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(tr('NOW PLAYING','SPELAS NU','TRENUTNO SVIRA'),style:const TextStyle(color:cyan,fontSize:10,letterSpacing:1.5)),
          const SizedBox(height:8),
          Row(children:[InkWell(onTap:()=>openPlayer(),child:artwork(current!,size:48)),const SizedBox(width:10),Expanded(child:InkWell(onTap:()=>openPlayer(),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(current!.name,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontWeight:FontWeight.bold)),StreamBuilder<String?>(stream:radio.nowPlaying,initialData:radio.nowPlaying.value,builder:(context,snapshot)=>Text(snapshot.data??current!.country,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Colors.white60,fontSize:12)))]))),IconButton(onPressed:()=>skip(-1),icon:const Icon(Icons.skip_previous)),StreamBuilder<PlaybackState>(stream:radio.playbackState,initialData:radio.playbackState.value,builder:(context,snapshot)=>IconButton(icon:Icon(snapshot.data?.playing==true?Icons.pause_circle_filled:Icons.play_circle_filled,color:cyan,size:36),onPressed:(){if(radio.playbackState.value.playing){radio.pause();}else{radio.play();}})),IconButton(onPressed:()=>skip(1),icon:const Icon(Icons.skip_next))])
        ]))
      ])),
      bottomNavigationBar:NavigationBar(backgroundColor:panel,indicatorColor:const Color(0xff29475a),selectedIndex:tab,onDestinationSelected:(i)=>setState(()=>tab=i),destinations:[NavigationDestination(icon:const Icon(Icons.home_outlined),label:tr('Home','Hem','Početna')),NavigationDestination(icon:const Icon(Icons.favorite_border),label:tr('Favorites','Favoriter','Omiljene')),NavigationDestination(icon:const Icon(Icons.history),label:tr('Recent','Senaste','Nedavno'))])
    ));
  }
}
