import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';

import 'settings_service.dart';
import 'tts/tts_engine.dart';
import 'tts/tts_engine_factory.dart';

/// =============================================================================
/// audio_feedback_service.dart
/// =============================================================================
/// Service de feedback audio pour confirmations vocales.
///
/// Utilisé pour confirmer les actions quand l'écran est verrouillé:
/// - "SMS envoyé à Pierre"
/// - "Alarme créée pour 7h"
/// - "Appel en cours vers Marie"
///
/// Deux chemins de synthèse :
/// - cloud (Gemini, ElevenLabs) quand `ttsProvider` le demande et que la clé
///   est renseignée : voix nettement plus naturelle en français ;
/// - local (flutter_tts) sinon, et en repli automatique dès qu'un appel cloud
///   échoue — hors-ligne, quota épuisé, clé invalide. Le retour vocal ne doit
///   jamais tomber en silence.
///
/// Les phrases synthétisées sont mises en cache sur disque : les formules
/// récurrentes ("Terminé", "J'écoute") ne repartent pas sur le réseau.
/// =============================================================================

class AudioFeedbackService {
  static AudioFeedbackService? _instance;

  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _player = AudioPlayer();

  bool _isInitialized = false;
  bool _enabled = true;
  bool _isSpeaking = false;

  /// Numéro de la prise de parole en cours, incrémenté à chaque `speak` et à
  /// chaque [stop].
  ///
  /// Le TTS local répond en quelques millisecondes, mais une synthèse cloud
  /// passe une à deux secondes sur le réseau. Sans ce compteur, un `stop()`
  /// déclenché pendant l'aller-retour — typiquement `audio_service` qui coupe
  /// Cobalt pour démarrer un enregistrement — n'annule rien : la réponse
  /// revient ensuite et se met à parler dans le micro ouvert.
  int _speakGeneration = 0;

  /// Répertoire du cache audio, résolu une fois à l'initialisation.
  Directory? _cacheDir;

  /// Nombre de fichiers au-delà duquel on élague le cache au démarrage.
  static const int _cacheMaxFiles = 120;

  /// Extensions produites par les moteurs cloud, pour retrouver une entrée
  /// de cache sans savoir d'avance quel moteur l'a écrite.
  static const List<String> _cacheExtensions = ['wav', 'mp3'];

  /// True si le TTS Cobalt est actuellement en train de parler
  bool get isSpeaking => _isSpeaking;

  /// Singleton
  factory AudioFeedbackService() {
    _instance ??= AudioFeedbackService._internal();
    return _instance!;
  }

  AudioFeedbackService._internal();

  /// Active/désactive le feedback vocal
  bool get isEnabled => _enabled;
  set enabled(bool value) => _enabled = value;

  /// Moteur cloud actif, ou null si on doit passer par le TTS local.
  ///
  /// Rend null aussi quand le fournisseur est choisi mais sa clé absente :
  /// mieux vaut une voix robotique qu'aucune voix.
  TtsEngine? get _cloudEngine {
    final engine = activeCloudEngine();
    if (engine == null) return null;
    return engine.isConfigured ? engine : null;
  }

  /// Initialise le service TTS
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // Configuration du TTS
      final lang = SettingsService().language;
      await _tts.setLanguage(lang == 'en' ? 'en-US' : 'fr-FR');
      await _tts.setSpeechRate(0.5); // Vitesse normale
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);

      // Tracker l'état de lecture TTS
      _tts.setStartHandler(() { _isSpeaking = true; });
      _tts.setCompletionHandler(() { _isSpeaking = false; });
      _tts.setCancelHandler(() { _isSpeaking = false; });
      _tts.setErrorHandler((_) { _isSpeaking = false; });

      // Utiliser le moteur TTS par défaut
      final engines = await _tts.getEngines;
      if (engines.isNotEmpty) {
        // ignore: avoid_print
        print('[AudioFeedback] Moteurs TTS disponibles: $engines');
      }

      // Contexte audio du lecteur cloud.
      //
      // Par défaut audioplayers s'annonce en `music` / `media` / focus `gain` :
      // Android prendrait la voix de Cobalt pour de la musique — ce que
      // `audio_service` interroge avant d'enregistrer — et couperait celle de
      // l'utilisateur sans la relancer. On déclare de la parole d'assistant en
      // focus transitoire : la musique baisse le temps de la confirmation puis
      // reprend d'elle-même. `flutter_tts` obtenait déjà ce comportement seul.
      await _player.setAudioContext(
        const AudioContext(
          android: AudioContextAndroid(
            contentType: AndroidContentType.speech,
            usageType: AndroidUsageType.assistant,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
            stayAwake: true,
          ),
        ),
      );

      await _initCache();

      _isInitialized = true;
      // ignore: avoid_print
      print('[AudioFeedback] Service initialisé '
          '(fournisseur: ${SettingsService().ttsProvider})');
    } catch (e) {
      // ignore: avoid_print
      print('[AudioFeedback] Erreur d\'initialisation: $e');
    }
  }

  /// Prononce un texte de confirmation
  Future<void> speak(String text) async {
    if (!_enabled || !_isInitialized || !SettingsService().ttsEnabled) return;

    if (await _speakCloud(text, wait: false) != _CloudOutcome.failed) return;
    await _speakLocal(text, wait: false);
  }

  /// Prononce un texte et attend la fin de la lecture TTS
  ///
  /// Contrairement à [speak] qui retourne immédiatement,
  /// cette méthode bloque jusqu'à ce que le TTS ait fini de parler.
  /// Utile pour enchaîner TTS → action (ex: briefing navigation → Maps).
  Future<void> speakAndWait(String text) async {
    if (!_enabled || !_isInitialized) return;

    if (await _speakCloud(text, wait: true) != _CloudOutcome.failed) return;
    await _speakLocal(text, wait: true);
  }

  // ---------------------------------------------------------------------------
  // CHEMIN CLOUD
  // ---------------------------------------------------------------------------

  /// Synthétise et joue [text] via le moteur cloud.
  ///
  /// Seul [_CloudOutcome.failed] autorise l'appelant à se rabattre sur le TTS
  /// local : une synthèse annulée l'a été volontairement, la reprendre en voix
  /// locale ferait parler Cobalt juste après qu'on lui a demandé de se taire.
  Future<_CloudOutcome> _speakCloud(String text, {required bool wait}) async {
    final engine = _cloudEngine;
    if (engine == null) return _CloudOutcome.failed;

    final locale = SettingsService().language == 'en' ? 'en-US' : 'fr-FR';
    final generation = ++_speakGeneration;

    // Parlant dès la synthèse, pas seulement à la lecture : pendant l'appel
    // réseau, Cobalt occupe déjà le canal vocal du point de vue de
    // `audio_service`, qui s'en sert pour ne pas confondre sa propre voix
    // avec la musique de l'utilisateur.
    _isSpeaking = true;

    try {
      final file = await _resolveAudioFile(engine, text, locale);
      if (file == null) {
        if (generation == _speakGeneration) _isSpeaking = false;
        return _CloudOutcome.failed;
      }

      if (generation != _speakGeneration) {
        // ignore: avoid_print
        print('[AudioFeedback] synthèse abandonnée (stop pendant l\'appel)');
        return _CloudOutcome.cancelled;
      }

      await _player.stop();

      // Souscrire AVANT play() : sur une phrase courte déjà en cache, la
      // lecture peut se terminer avant qu'on ait eu le temps d'écouter.
      final completion = _player.onPlayerComplete.first
          .timeout(const Duration(seconds: 60), onTimeout: () {})
          .whenComplete(() {
        // Ne pas écraser l'état d'une prise de parole plus récente.
        if (generation == _speakGeneration) _isSpeaking = false;
      });

      await _player.play(DeviceFileSource(file.path));

      if (wait) {
        await completion;
      } else {
        // On laisse le future vivre sa vie, sans laisser une erreur non
        // capturée remonter jusqu'à la zone.
        unawaited(completion.catchError((_) {}));
      }

      // ignore: avoid_print
      print('[AudioFeedback] ${engine.id} → "$text"');
      return _CloudOutcome.played;
    } catch (e) {
      if (generation == _speakGeneration) _isSpeaking = false;
      // ignore: avoid_print
      print('[AudioFeedback] Échec cloud (${engine.id}), repli local: $e');
      return _CloudOutcome.failed;
    }
  }

  /// Rend le fichier audio pour [text] : depuis le cache, sinon synthétisé.
  Future<File?> _resolveAudioFile(
    TtsEngine engine,
    String text,
    String locale,
  ) async {
    final key = _cacheKey(engine, text, locale);

    final cached = await _lookupCache(key);
    if (cached != null) {
      // ignore: avoid_print
      print('[AudioFeedback] cache hit ($key)');
      return cached;
    }

    final audio = await engine.synthesize(text, locale: locale);
    if (audio == null || audio.bytes.isEmpty) return null;

    return _writeCache(key, audio);
  }

  /// Clé de cache : moteur + voix + langue + texte.
  ///
  /// La voix entre dans la clé pour qu'un changement de voix dans les réglages
  /// ne rejoue pas l'ancienne.
  String _cacheKey(TtsEngine engine, String text, String locale) {
    final settings = SettingsService();
    final material = [
      engine.id,
      settings.ttsVoice,
      settings.elevenLabsVoiceId,
      locale,
      text,
    ].join('|');
    return sha1.convert(utf8.encode(material)).toString();
  }

  Future<File?> _lookupCache(String key) async {
    final dir = _cacheDir;
    if (dir == null) return null;

    for (final ext in _cacheExtensions) {
      final file = File('${dir.path}${Platform.pathSeparator}$key.$ext');
      if (await file.exists()) return file;
    }
    return null;
  }

  Future<File?> _writeCache(String key, TtsAudio audio) async {
    final dir = _cacheDir;
    if (dir == null) return null;

    try {
      final file =
          File('${dir.path}${Platform.pathSeparator}$key.${audio.extension}');
      await file.writeAsBytes(audio.bytes, flush: true);
      return file;
    } catch (e) {
      // ignore: avoid_print
      print('[AudioFeedback] Écriture cache impossible: $e');
      return null;
    }
  }

  /// Crée le répertoire de cache et élague les entrées les plus anciennes.
  Future<void> _initCache() async {
    try {
      final tmp = await getTemporaryDirectory();
      final dir = Directory('${tmp.path}${Platform.pathSeparator}tts_cache');
      if (!await dir.exists()) await dir.create(recursive: true);
      _cacheDir = dir;

      final files =
          await dir.list().where((e) => e is File).cast<File>().toList();
      if (files.length <= _cacheMaxFiles) return;

      files.sort(
          (a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      for (final file in files.take(files.length - _cacheMaxFiles)) {
        await file.delete();
      }
      // ignore: avoid_print
      print('[AudioFeedback] Cache élagué à $_cacheMaxFiles fichiers');
    } catch (e) {
      // ignore: avoid_print
      print('[AudioFeedback] Cache indisponible: $e');
      _cacheDir = null;
    }
  }

  // ---------------------------------------------------------------------------
  // CHEMIN LOCAL (flutter_tts) — repli hors-ligne
  // ---------------------------------------------------------------------------

  Future<void> _speakLocal(String text, {required bool wait}) async {
    // Appliquer la langue à chaque appel (peut changer dans les settings)
    final lang = SettingsService().language;
    await _tts.setLanguage(lang == 'en' ? 'en-US' : 'fr-FR');

    if (!wait) {
      try {
        await _tts.speak(text);
        // ignore: avoid_print
        print('[AudioFeedback] Prononcé: "$text"');
      } catch (e) {
        // ignore: avoid_print
        print('[AudioFeedback] Erreur speak: $e');
      }
      return;
    }

    try {
      final completer = Completer<void>();

      // On pose des handlers temporaires qui complètent le completer
      // ET maintiennent le flag _isSpeaking correctement
      _tts.setCompletionHandler(() {
        _isSpeaking = false;
        if (!completer.isCompleted) completer.complete();
      });

      _tts.setErrorHandler((msg) {
        _isSpeaking = false;
        if (!completer.isCompleted) completer.completeError(msg);
      });

      await _tts.speak(text);
      await completer.future;

      // Remettre les handlers permanents
      _tts.setCompletionHandler(() { _isSpeaking = false; });
      _tts.setErrorHandler((_) { _isSpeaking = false; });

      // ignore: avoid_print
      print('[AudioFeedback] speakAndWait terminé: "$text"');
    } catch (e) {
      _isSpeaking = false;
      // ignore: avoid_print
      print('[AudioFeedback] Erreur speakAndWait: $e');
    }
  }

  /// Confirme une action exécutée
  Future<void> confirmAction(String actionType, String details) async {
    final message = _buildConfirmationMessage(actionType, details);
    await speak(message);
  }

  /// Construit le message de confirmation selon le type d'action
  String _buildConfirmationMessage(String actionType, String details) {
    switch (actionType.toLowerCase()) {
      case 'sms':
        return 'SMS envoyé à $details';
      case 'call':
        return 'Appel vers $details';
      case 'alarm':
        return 'Alarme créée pour $details';
      case 'timer':
        return 'Minuteur de $details lancé';
      case 'calendar':
        return 'Événement $details créé';
      case 'task':
        return 'Tâche $details ajoutée';
      case 'volume':
        return 'Volume $details';
      case 'flashlight':
        return 'Lampe torche $details';
      case 'navigation':
        return 'Navigation vers $details';
      case 'whatsapp':
        return 'Message WhatsApp envoyé à $details';
      case 'error':
        return 'Erreur: $details';
      default:
        return details;
    }
  }

  /// Bip de début d'enregistrement
  Future<void> playStartSound() async {
    if (!SettingsService().confirmationSound) return;
    try {
      await SystemSound.play(SystemSoundType.click);
      await HapticFeedback.mediumImpact();
    } catch (_) {}
  }

  /// Bip de fin d'enregistrement
  Future<void> playStopSound() async {
    if (!SettingsService().confirmationSound) return;
    try {
      await HapticFeedback.heavyImpact();
    } catch (_) {}
  }

  /// Vibration de confirmation quand une commande est validée et exécutée
  Future<void> playCommandValidated() async {
    if (!SettingsService().confirmationVibration) return;
    try {
      await HapticFeedback.mediumImpact();
      await Future.delayed(const Duration(milliseconds: 100));
      await HapticFeedback.mediumImpact();
    } catch (_) {}
  }

  /// Annonce une erreur
  Future<void> announceError(String error) async {
    await speak('Erreur. $error');
  }

  /// Annonce que l'écoute est active
  Future<void> announceListening() async {
    await speak('J\'écoute');
  }

  /// Annonce la fin du traitement
  Future<void> announceComplete() async {
    await speak('Terminé');
  }

  /// Teste le moteur cloud sélectionné et rend un message d'état lisible.
  ///
  /// Utilisé par l'écran de réglages : sans ça, une clé invalide ne se voit
  /// qu'au moment où l'assistant retombe silencieusement sur la voix locale.
  Future<String> testCloudEngine() async {
    const phrase = 'Bonjour, la synthèse vocale Cobalt fonctionne.';

    final engine = activeCloudEngine();
    if (engine == null) return 'Voix locale (hors-ligne) — rien à tester.';
    if (!engine.isConfigured) {
      return 'Clé API ${engine.displayName} manquante.';
    }

    final audio = await engine.synthesize(phrase);
    if (audio == null || audio.bytes.isEmpty) {
      return 'Échec ${engine.displayName} — repli sur la voix locale. '
          'Voir les logs.';
    }

    await speak(phrase);
    return '${engine.displayName} OK (${audio.bytes.length ~/ 1024} Ko).';
  }

  /// Arrête la lecture en cours
  ///
  /// Invalide aussi la synthèse cloud éventuellement en vol : sans ça elle
  /// reviendrait du réseau après le stop et se mettrait à parler.
  Future<void> stop() async {
    _speakGeneration++;
    await _tts.stop();
    await _player.stop();
    _isSpeaking = false;
  }

  /// Libère les ressources
  void dispose() {
    _tts.stop();
    _player.dispose();
    // ignore: avoid_print
    print('[AudioFeedback] Ressources libérées');
  }
}

/// Issue d'une tentative de synthèse cloud.
enum _CloudOutcome {
  /// Audio obtenu et lecture démarrée.
  played,

  /// stop() est passé pendant l'appel réseau : ne rien jouer, ne pas replier.
  cancelled,

  /// Pas de moteur, échec réseau ou audio vide : replier sur le TTS local.
  failed,
}
