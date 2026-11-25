import 'package:flutter_test/flutter_test.dart';
import 'package:wavedrive/radio_api.dart';

void main() {
  test('worldwide name search omits empty country code', () {
    final query=RadioApi.searchParameters('  Radio  ','');
    expect(query['name'],'Radio');
    expect(query.containsKey('countrycode'),isFalse);
  });
  test('selected country limits results', () {
    final query=RadioApi.searchParameters('Radio',' se ');
    expect(query['name'],'Radio');
    expect(query['countrycode'],'SE');
  });
  test('popular worldwide stations omit both empty filters', () {
    final query=RadioApi.searchParameters(' ',' ');
    expect(query.containsKey('name'),isFalse);
    expect(query.containsKey('countrycode'),isFalse);
    expect(query['order'],'votes');
    expect(query['hidebroken'],'true');
  });
  test('country-only search omits empty name', () {
    final query=RadioApi.searchParameters('','HR');
    expect(query.containsKey('name'),isFalse);
    expect(query['countrycode'],'HR');
  });
}
