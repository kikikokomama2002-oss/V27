import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _languagePreferenceKey = 'v27_language_code_v1';
const v27Languages = <({String code, String name, Locale locale})>[
  (code: 'en', name: 'English', locale: Locale('en')),
  (code: 'ar', name: 'العربية', locale: Locale('ar')),
  (code: 'fr', name: 'Français', locale: Locale('fr')),
  (code: 'es', name: 'Español', locale: Locale('es')),
  (code: 'de', name: 'Deutsch', locale: Locale('de')),
  (code: 'pt', name: 'Português', locale: Locale('pt')),
  (code: 'tr', name: 'Türkçe', locale: Locale('tr')),
  (code: 'ja', name: '日本語', locale: Locale('ja')),
  (code: 'ar_MA', name: 'الدارجة المغربية', locale: Locale('ar', 'MA')),
];

final languageProvider = StateNotifierProvider<LanguageController, String>(
  (ref) => LanguageController(),
);

Locale localeForLanguage(String code) => v27Languages
    .firstWhere((item) => item.code == code, orElse: () => v27Languages.first)
    .locale;

class LanguageController extends StateNotifier<String> {
  LanguageController() : super('en') { _load(); }
  bool _changed = false;
  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_languagePreferenceKey);
      if (!_changed && v27Languages.any((item) => item.code == saved)) state = saved!;
    } catch (_) {}
  }
  Future<void> select(String code) async {
    if (!v27Languages.any((item) => item.code == code)) return;
    _changed = true;
    state = code;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_languagePreferenceKey, code);
    } catch (_) {}
  }
}

/// App-owned localization delegate. This initial dictionary covers the
/// language/settings and Now Playing controls; remaining screens need keys
/// added before claiming full-app translation coverage.
class V27Strings {
  const V27Strings(this.locale);
  final Locale locale;
  static V27Strings of(BuildContext context) => Localizations.of<V27Strings>(context, V27Strings)!;

  static const _translations = <String, Map<String, String>>{
    'en': {'settings':'Settings','language':'Language','accent_color':'Accent color','now_playing':'NOW PLAYING','lyrics':'Lyrics','whats_next':"What's Next",'sleep_timer':'Sleep timer','cancel':'Cancel','play':'Play','choose_language':'Choose app language','personalize_accent':'Personalize buttons and highlights','checking_timer':'Checking active timer…','stop_after':'Stop playback automatically after:','timer_stops_in':'Playback will stop in','could_not_start_timer':'Could not start the sleep timer.','could_not_cancel_timer':'Could not cancel the sleep timer.','custom_duration':'Custom duration','minutes':'minutes','start':'Start','cancel_timer':'Cancel timer','no_lyrics_found':'No lyrics found','could_not_load_lyrics':'Could not load lyrics','open_lyrics_tools':'Open lyrics tools','no_upcoming_tracks':'No upcoming tracks','equalizer':'Equalizer','loading_timer':'Loading timer…','stop_playback_set_time':'Stop playback after a set time','cancel_sleep_timer':'Cancel sleep timer','sleep_timer_finished':'Sleep timer finished. Playback paused.','stop_playback_after':'Stop playback after','cancel_active_timer':'Cancel active timer','remaining':'remaining','custom_sleep_timer':'Custom sleep timer','enter_duration':'Enter a duration from 1 to 720 minutes.','whole_number':'Enter a whole number from 1 to 720.'},
    'ar': {'settings':'الإعدادات','language':'اللغة','accent_color':'لون الواجهة','now_playing':'يُشغَّل الآن','lyrics':'كلمات الأغنية','whats_next':'التالي','sleep_timer':'مؤقت النوم','cancel':'إلغاء','play':'تشغيل','choose_language':'اختر لغة التطبيق','personalize_accent':'خصّص الأزرار والألوان البارزة','checking_timer':'جارٍ التحقق من المؤقت…','stop_after':'إيقاف التشغيل تلقائياً بعد:','timer_stops_in':'سيتوقف التشغيل بعد','could_not_start_timer':'تعذر تشغيل مؤقت النوم.','could_not_cancel_timer':'تعذر إلغاء مؤقت النوم.','custom_duration':'مدة مخصصة','minutes':'دقيقة','start':'بدء','cancel_timer':'إلغاء المؤقت','no_lyrics_found':'لم يتم العثور على كلمات الأغنية','could_not_load_lyrics':'تعذر تحميل الكلمات','open_lyrics_tools':'فتح أدوات الكلمات','no_upcoming_tracks':'لا توجد أغانٍ قادمة','equalizer':'معادل الصوت','loading_timer':'جارٍ تحميل المؤقت…','stop_playback_set_time':'إيقاف التشغيل بعد مدة محددة','cancel_sleep_timer':'إلغاء مؤقت النوم','sleep_timer_finished':'انتهى مؤقت النوم. تم إيقاف التشغيل.','stop_playback_after':'إيقاف التشغيل بعد','cancel_active_timer':'إلغاء المؤقت النشط','remaining':'متبقية','custom_sleep_timer':'مؤقت نوم مخصص','enter_duration':'أدخل مدة من 1 إلى 720 دقيقة.','whole_number':'أدخل عدداً صحيحاً من 1 إلى 720.'},
    'fr': {'settings':'Paramètres','language':'Langue','accent_color':'Couleur d’accentuation','now_playing':'EN COURS DE LECTURE','lyrics':'Paroles','whats_next':'À suivre','sleep_timer':'Minuteur de veille','cancel':'Annuler','play':'Lire','choose_language':'Choisir la langue de l’application','personalize_accent':'Personnaliser les boutons et les accents','checking_timer':'Vérification du minuteur…','stop_after':'Arrêter automatiquement la lecture après :','timer_stops_in':'La lecture s’arrêtera dans','could_not_start_timer':'Impossible de démarrer le minuteur.','could_not_cancel_timer':'Impossible d’annuler le minuteur.','custom_duration':'Durée personnalisée','minutes':'minutes','start':'Démarrer','cancel_timer':'Annuler le minuteur','no_lyrics_found':'Aucune parole trouvée','could_not_load_lyrics':'Impossible de charger les paroles','open_lyrics_tools':'Ouvrir les outils de paroles','no_upcoming_tracks':'Aucun morceau à venir','equalizer':'Égaliseur','loading_timer':'Chargement du minuteur…','stop_playback_set_time':'Arrêter la lecture après une durée définie','cancel_sleep_timer':'Annuler le minuteur de veille','sleep_timer_finished':'Minuteur terminé. Lecture en pause.','stop_playback_after':'Arrêter la lecture après','cancel_active_timer':'Annuler le minuteur actif','remaining':'restantes','custom_sleep_timer':'Minuteur personnalisé','enter_duration':'Saisissez une durée de 1 à 720 minutes.','whole_number':'Saisissez un nombre entier de 1 à 720.'},
    'es': {'settings':'Ajustes','language':'Idioma','accent_color':'Color de acento','now_playing':'REPRODUCIENDO','lyrics':'Letra','whats_next':'A continuación','sleep_timer':'Temporizador','cancel':'Cancelar','play':'Reproducir','choose_language':'Elegir el idioma de la aplicación','personalize_accent':'Personaliza botones y resaltados','checking_timer':'Comprobando temporizador…','stop_after':'Detener la reproducción automáticamente después de:','timer_stops_in':'La reproducción se detendrá en','could_not_start_timer':'No se pudo iniciar el temporizador.','could_not_cancel_timer':'No se pudo cancelar el temporizador.','custom_duration':'Duración personalizada','minutes':'minutos','start':'Iniciar','cancel_timer':'Cancelar temporizador','no_lyrics_found':'No se encontraron letras','could_not_load_lyrics':'No se pudieron cargar las letras','open_lyrics_tools':'Abrir herramientas de letras','no_upcoming_tracks':'No hay canciones siguientes','equalizer':'Ecualizador','loading_timer':'Cargando temporizador…','stop_playback_set_time':'Detener la reproducción después de un tiempo','cancel_sleep_timer':'Cancelar temporizador de apagado','sleep_timer_finished':'Temporizador finalizado. Reproducción pausada.','stop_playback_after':'Detener la reproducción después de','cancel_active_timer':'Cancelar temporizador activo','remaining':'restantes','custom_sleep_timer':'Temporizador personalizado','enter_duration':'Introduce una duración de 1 a 720 minutos.','whole_number':'Introduce un número entero del 1 al 720.'},
    'de': {'settings':'Einstellungen','language':'Sprache','accent_color':'Akzentfarbe','now_playing':'WIEDERGABE','lyrics':'Songtext','whats_next':'Als Nächstes','sleep_timer':'Sleeptimer','cancel':'Abbrechen','play':'Abspielen','choose_language':'App-Sprache auswählen','personalize_accent':'Schaltflächen und Akzente anpassen','checking_timer':'Timer wird geprüft…','stop_after':'Wiedergabe automatisch beenden nach:','timer_stops_in':'Die Wiedergabe endet in','could_not_start_timer':'Der Sleep-Timer konnte nicht gestartet werden.','could_not_cancel_timer':'Der Sleep-Timer konnte nicht abgebrochen werden.','custom_duration':'Benutzerdefinierte Dauer','minutes':'Minuten','start':'Starten','cancel_timer':'Timer abbrechen','no_lyrics_found':'Keine Songtexte gefunden','could_not_load_lyrics':'Songtexte konnten nicht geladen werden','open_lyrics_tools':'Songtext-Werkzeuge öffnen','no_upcoming_tracks':'Keine nächsten Titel','equalizer':'Equalizer','loading_timer':'Timer wird geladen…','stop_playback_set_time':'Wiedergabe nach einer festgelegten Zeit stoppen','cancel_sleep_timer':'Sleep-Timer abbrechen','sleep_timer_finished':'Timer beendet. Wiedergabe pausiert.','stop_playback_after':'Wiedergabe beenden nach','cancel_active_timer':'Aktiven Timer abbrechen','remaining':'verbleibend','custom_sleep_timer':'Benutzerdefinierter Sleep-Timer','enter_duration':'Gib eine Dauer von 1 bis 720 Minuten ein.','whole_number':'Gib eine ganze Zahl von 1 bis 720 ein.'},
    'pt': {'settings':'Definições','language':'Idioma','accent_color':'Cor de destaque','now_playing':'A REPRODUZIR','lyrics':'Letra','whats_next':'A seguir','sleep_timer':'Temporizador','cancel':'Cancelar','play':'Reproduzir','choose_language':'Escolher o idioma da aplicação','personalize_accent':'Personalizar botões e destaques','checking_timer':'A verificar o temporizador…','stop_after':'Parar a reprodução automaticamente após:','timer_stops_in':'A reprodução vai parar em','could_not_start_timer':'Não foi possível iniciar o temporizador.','could_not_cancel_timer':'Não foi possível cancelar o temporizador.','custom_duration':'Duração personalizada','minutes':'minutos','start':'Iniciar','cancel_timer':'Cancelar temporizador','no_lyrics_found':'Não foram encontradas letras','could_not_load_lyrics':'Não foi possível carregar as letras','open_lyrics_tools':'Abrir ferramentas de letras','no_upcoming_tracks':'Não há faixas seguintes','equalizer':'Equalizador','loading_timer':'A carregar o temporizador…','stop_playback_set_time':'Parar a reprodução após um período definido','cancel_sleep_timer':'Cancelar temporizador de suspensão','sleep_timer_finished':'Temporizador terminado. Reprodução em pausa.','stop_playback_after':'Parar a reprodução após','cancel_active_timer':'Cancelar temporizador ativo','remaining':'restantes','custom_sleep_timer':'Temporizador personalizado','enter_duration':'Introduza uma duração entre 1 e 720 minutos.','whole_number':'Introduza um número inteiro entre 1 e 720.'},
    'tr': {'settings':'Ayarlar','language':'Dil','accent_color':'Vurgu rengi','now_playing':'ŞİMDİ ÇALIYOR','lyrics':'Şarkı sözleri','whats_next':'Sıradaki','sleep_timer':'Uyku zamanlayıcısı','cancel':'İptal','play':'Çal','choose_language':'Uygulama dilini seç','personalize_accent':'Düğmeleri ve vurguları kişiselleştir','checking_timer':'Zamanlayıcı kontrol ediliyor…','stop_after':'Çalmayı şu süre sonra otomatik durdur:','timer_stops_in':'Çalma şu süre sonra duracak:','could_not_start_timer':'Uyku zamanlayıcısı başlatılamadı.','could_not_cancel_timer':'Uyku zamanlayıcısı iptal edilemedi.','custom_duration':'Özel süre','minutes':'dakika','start':'Başlat','cancel_timer':'Zamanlayıcıyı iptal et','no_lyrics_found':'Şarkı sözü bulunamadı','could_not_load_lyrics':'Şarkı sözleri yüklenemedi','open_lyrics_tools':'Şarkı sözü araçlarını aç','no_upcoming_tracks':'Sırada parça yok','equalizer':'Ekolayzer','loading_timer':'Zamanlayıcı yükleniyor…','stop_playback_set_time':'Çalmayı belirli bir süre sonra durdur','cancel_sleep_timer':'Uyku zamanlayıcısını iptal et','sleep_timer_finished':'Zamanlayıcı bitti. Çalma duraklatıldı.','stop_playback_after':'Şu süre sonra çalmayı durdur','cancel_active_timer':'Etkin zamanlayıcıyı iptal et','remaining':'kaldı','custom_sleep_timer':'Özel uyku zamanlayıcısı','enter_duration':'1 ile 720 dakika arasında bir süre girin.','whole_number':'1 ile 720 arasında tam sayı girin.'},
    'ja': {'settings':'設定','language':'言語','accent_color':'アクセントカラー','now_playing':'再生中','lyrics':'歌詞','whats_next':'次に再生','sleep_timer':'スリープタイマー','cancel':'キャンセル','play':'再生','choose_language':'アプリの言語を選択','personalize_accent':'ボタンとアクセントをカスタマイズ','checking_timer':'タイマーを確認中…','stop_after':'次の時間が経過したら再生を停止:','timer_stops_in':'再生停止まで','could_not_start_timer':'スリープタイマーを開始できませんでした。','could_not_cancel_timer':'スリープタイマーをキャンセルできませんでした。','custom_duration':'カスタム時間','minutes':'分','start':'開始','cancel_timer':'タイマーをキャンセル','no_lyrics_found':'歌詞が見つかりません','could_not_load_lyrics':'歌詞を読み込めませんでした','open_lyrics_tools':'歌詞ツールを開く','no_upcoming_tracks':'次の曲はありません','equalizer':'イコライザー','loading_timer':'タイマーを読み込み中…','stop_playback_set_time':'指定した時間後に再生を停止','cancel_sleep_timer':'スリープタイマーをキャンセル','sleep_timer_finished':'タイマー終了。再生を一時停止しました。','stop_playback_after':'再生停止まで','cancel_active_timer':'実行中のタイマーをキャンセル','remaining':'残り','custom_sleep_timer':'カスタムスリープタイマー','enter_duration':'1〜720分の時間を入力してください。','whole_number':'1〜720の整数を入力してください。'},
    'ar_MA': {'settings':'الإعدادات','language':'اللغة','accent_color':'لون التطبيق','now_playing':'دابا كيتشغل','lyrics':'كلمات الأغنية','whats_next':'شنو جاي','sleep_timer':'مؤقت النوم','cancel':'إلغاء','play':'شغّل','choose_language':'اختار لغة التطبيق','personalize_accent':'بدّل ألوان الأزرار والواجهة','checking_timer':'كنتحقق من مؤقت النوم…','stop_after':'حبس الموسيقى أوتوماتيكياً من بعد:','timer_stops_in':'الموسيقى غادي تحبس من بعد','could_not_start_timer':'ما قدرناش نشغلو مؤقت النوم.','could_not_cancel_timer':'ما قدرناش نلغيو مؤقت النوم.','custom_duration':'مدة مخصصة','minutes':'دقيقة','start':'بدا','cancel_timer':'لغي المؤقت','no_lyrics_found':'ما لقيناش كلمات الأغنية','could_not_load_lyrics':'ما قدرناش نحملو الكلمات','open_lyrics_tools':'حل أدوات الكلمات','no_upcoming_tracks':'ما كايناش أغاني جاية','equalizer':'معادل الصوت','loading_timer':'كنحمّلو المؤقت…','stop_playback_set_time':'حبس الموسيقى من بعد مدة معينة','cancel_sleep_timer':'لغي مؤقت النوم','sleep_timer_finished':'سالَى مؤقت النوم وتوقفت الموسيقى.','stop_playback_after':'حبس الموسيقى من بعد','cancel_active_timer':'لغي المؤقت اللي خدام','remaining':'باقية','custom_sleep_timer':'مؤقت نوم مخصص','enter_duration':'دخل مدة بين دقيقة و720 دقيقة.','whole_number':'دخل عدد صحيح بين 1 و720.'},
  };
  String text(String key) => _translations[locale.toString()]?[key] ?? _translations[locale.languageCode]?[key] ?? _translations['en']![key] ?? key;
}

class V27StringsDelegate extends LocalizationsDelegate<V27Strings> {
  const V27StringsDelegate();
  @override
  bool isSupported(Locale locale) => v27Languages.any((item) => item.locale.languageCode == locale.languageCode);
  @override
  Future<V27Strings> load(Locale locale) => SynchronousFuture(V27Strings(locale));
  @override
  bool shouldReload(V27StringsDelegate old) => false;
}
