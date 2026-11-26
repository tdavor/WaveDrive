import 'dart:convert';
import 'package:http/http.dart' as http;

class Station {
  final String id, name, url, country, logo;
  const Station(this.id,this.name,this.url,this.country,this.logo);
  factory Station.fromJson(Map<String,dynamic> j) => Station(
    j['stationuuid'] ?? '', j['name'] ?? '', j['url_resolved'] ?? '',
    j['country'] ?? '', j['favicon'] ?? '');
  Map<String,dynamic> toJson()=>{'stationuuid':id,'name':name,'url_resolved':url,'country':country,'favicon':logo};
}
class RadioApi {
  static Map<String,String> searchParameters(String name,String country){
    final term=name.trim();
    final code=country.trim().toUpperCase();
    return {
      if(term.isNotEmpty) 'name':term,
      if(code.isNotEmpty) 'countrycode':code,
      'hidebroken':'true','order':'votes','reverse':'true','limit':'100',
    };
  }
  Future<List<Station>> search(String name, String country,{String tag=''}) async {
    final parameters=searchParameters(name,country);
    if(tag.trim().isNotEmpty)parameters['tag']=tag.trim();
    for(final host in ['de1.api.radio-browser.info','nl1.api.radio-browser.info']) {
      try {
        final uri=Uri.https(host,'/json/stations/search',parameters);
        final response=await http.get(uri,headers:{'User-Agent':'WaveDrive/1.0.0'}).timeout(const Duration(seconds:12));
        if(response.statusCode!=200) continue;
        return (jsonDecode(response.body) as List).map((j)=>Station.fromJson(Map<String,dynamic>.from(j))).where((s)=>s.url.startsWith('https://')||s.url.startsWith('http://')).toList();
      } catch (_) { continue; }
    }
    throw Exception('Radio directory unavailable');
  }
}
