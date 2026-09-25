import 'dart:convert';

import 'package:http/http.dart' as http;

import '../settings_service.dart';
import 'tts_engine.dart';

/// =============================================================================
/// elevenlabs_tts_engine.dart
/// =============================================================================
/// Synthèse vocale via ElevenLabs — la meilleure qualité de français des
/// fournisseurs testés, mais un compte et des crédits en plus.
///
/// Modèle par défaut : eleven_flash_v2_5 (~75 ms de latence, 29 langues,
/// 0,5 crédit par caractère). Repli : eleven_multilingual_v2 (plus naturel,
/// 1 crédit par caractère).
///
/// L'API rend directement du MP3 : aucun ré-emballage nécessaire.
/// =============================================================================

class ElevenLabsTtsEngine implements TtsEngine {
  static const String _baseUrl = 'https://api.elevenlabs.io/v1';
  static const String _primaryModel = 'eleven_flash_v2_5';
  static const String _fallbackModel = 'eleven_multilingual_v2';
  static const String _outputFormat = 'mp3_44100_128';

  final http.Client _client;

  /// Voix résolue via /v1/voices quand aucune n'est configurée à la main.
  /// Évite de figer dans le code des identifiants de voix qui peuvent changer.
  String? _autoVoiceId;

  ElevenLabsTtsEngine({http.Client? client}) : _client = client ?? http.Client();

  @override
  String get id => 'elevenlabs';

  @override
  String get displayName => 'ElevenLabs';

  @override
  bool get isConfigured => SettingsService().elevenLabsApiKey.trim().isNotEmpty;

  @override
  Future<TtsAudio?> synthesize(String text, {String locale = 'fr-FR'}) async {
    final apiKey = SettingsService().elevenLabsApiKey.trim();
    if (apiKey.isEmpty) return null;

    final voiceId = await _resolveVoiceId(apiKey);
    if (voiceId == null) {
      // ignore: avoid_print
      print('[ElevenLabs] aucune voix disponible sur ce compte');
      return null;
    }

    var audio = await _request(_primaryModel, apiKey, voiceId, text, locale);
    audio ??= await _request(_fallbackModel, apiKey, voiceId, text, locale);
    return audio;
  }

  Future<TtsAudio?> _request(
    String model,
    String apiKey,
    String voiceId,
    String text,
    String locale,
  ) async {
    final uri = Uri.parse(
      '$_baseUrl/text-to-speech/$voiceId?output_format=$_outputFormat',
    );

    final body = <String, dynamic>{
      'text': text,
      'model_id': model,
      // Force la langue au lieu de la laisser deviner : les confirmations sont
      // des phrases très courtes, terrain peu favorable à la détection auto.
      'language_code': locale.split('-').first,
    };

    try {
      final response = await _client
          .post(
            uri,
            headers: {
              'xi-api-key': apiKey,
              'Content-Type': 'application/json',
              'Accept': 'audio/mpeg',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        // ignore: avoid_print
        print('[ElevenLabs] $model → HTTP ${response.statusCode}: '
            '${_truncate(response.body)}');
        return null;
      }

      if (response.bodyBytes.isEmpty) {
        // ignore: avoid_print
        print('[ElevenLabs] $model → réponse audio vide');
        return null;
      }

      // ignore: avoid_print
      print('[ElevenLabs] $model → ${response.bodyBytes.length} octets MP3');
      return TtsAudio(response.bodyBytes, 'mp3');
    } catch (e) {
      // ignore: avoid_print
      print('[ElevenLabs] $model → erreur: $e');
      return null;
    }
  }

  /// Voix configurée dans les réglages, sinon première voix du compte.
  Future<String?> _resolveVoiceId(String apiKey) async {
    final configured = SettingsService().elevenLabsVoiceId.trim();
    if (configured.isNotEmpty) return configured;
    if (_autoVoiceId != null) return _autoVoiceId;

    try {
      final response = await _client.get(
        Uri.parse('$_baseUrl/voices'),
        headers: {'xi-api-key': apiKey},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final voices = json['voices'] as List?;
      if (voices == null || voices.isEmpty) return null;

      _autoVoiceId = (voices.first as Map)['voice_id'] as String?;
      // ignore: avoid_print
      print('[ElevenLabs] voix auto-sélectionnée: $_autoVoiceId');
      return _autoVoiceId;
    } catch (e) {
      // ignore: avoid_print
      print('[ElevenLabs] /voices → erreur: $e');
      return null;
    }
  }

  String _truncate(String s) => s.length <= 200 ? s : '${s.substring(0, 200)}…';
}
