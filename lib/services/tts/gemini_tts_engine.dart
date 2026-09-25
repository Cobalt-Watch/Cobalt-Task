import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../settings_service.dart';
import 'tts_engine.dart';

/// =============================================================================
/// gemini_tts_engine.dart
/// =============================================================================
/// Synthèse vocale via l'API Gemini (Google AI Studio).
///
/// Pourquoi ce fournisseur par défaut :
/// - Groq n'a aucun modèle TTS francophone (Orpheus = anglais + arabe saoudien).
/// - La clé Gemini est déjà saisie dans l'app (briefing navigation) : aucun
///   compte ni clé supplémentaire à créer.
/// - Le français fait partie des 90+ langues, détecté automatiquement.
///
/// L'API rend du PCM brut base64 (24 kHz, mono, 16 bits) qu'on emballe en WAV.
/// Réf: https://ai.google.dev/gemini-api/docs/generate-content/speech-generation
/// =============================================================================

class GeminiTtsEngine implements TtsEngine {
  /// Modèle principal. Les modèles TTS Gemini sont tous en "preview" : si
  /// celui-ci n'est pas exposé sur la clé utilisée, on retombe sur [_fallbackModel].
  static const String _primaryModel = 'gemini-3.1-flash-tts-preview';
  static const String _fallbackModel = 'gemini-2.5-flash-preview-tts';

  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  /// Voix disponibles (sous-ensemble des 30 voix Gemini) : Kore est posée et
  /// neutre, Aoede légère, Puck enjouée, Charon grave, Zephyr claire.
  static const Map<String, String> voices = {
    'Kore': 'Kore',
    'Aoede': 'Aoede',
    'Puck': 'Puck',
    'Charon': 'Charon',
    'Zephyr': 'Zephyr',
  };

  static const String defaultVoice = 'Kore';

  /// Consigne de style. Gemini interprète une directive en tête de prompt sans
  /// la prononcer. Elle stabilise l'accent français et évite le ton "lecture".
  static const String _stylePrompt =
      'Prononce ce texte en français, d\'un ton neutre, posé et naturel : ';

  final http.Client _client;

  GeminiTtsEngine({http.Client? client}) : _client = client ?? http.Client();

  @override
  String get id => 'gemini';

  @override
  String get displayName => 'Gemini TTS';

  @override
  bool get isConfigured => SettingsService().geminiApiKey.trim().isNotEmpty;

  @override
  Future<TtsAudio?> synthesize(String text, {String locale = 'fr-FR'}) async {
    final apiKey = SettingsService().geminiApiKey.trim();
    if (apiKey.isEmpty) return null;

    final voice = _resolveVoice();
    final prompt = locale.startsWith('fr') ? '$_stylePrompt$text' : text;

    var audio = await _request(_primaryModel, apiKey, prompt, voice);
    audio ??= await _request(_fallbackModel, apiKey, prompt, voice);
    return audio;
  }

  /// Une tentative sur un modèle donné. Rend null sur n'importe quel échec :
  /// l'appelant enchaîne sur le modèle de repli, puis sur le TTS local.
  Future<TtsAudio?> _request(
    String model,
    String apiKey,
    String prompt,
    String voice,
  ) async {
    final uri = Uri.parse('$_baseUrl/$model:generateContent?key=$apiKey');

    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt}
          ]
        }
      ],
      'generationConfig': {
        'responseModalities': ['AUDIO'],
        'speechConfig': {
          'voiceConfig': {
            'prebuiltVoiceConfig': {'voiceName': voice}
          }
        }
      }
    });

    try {
      final response = await _client
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) {
        // ignore: avoid_print
        print('[GeminiTTS] $model → HTTP ${response.statusCode}: '
            '${_truncate(response.body)}');
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final part = _firstPart(json);
      if (part == null) {
        // ignore: avoid_print
        print('[GeminiTTS] $model → réponse sans partie audio');
        return null;
      }

      final inlineData = part['inlineData'] as Map<String, dynamic>?;
      final data = inlineData?['data'] as String?;
      if (data == null || data.isEmpty) {
        // ignore: avoid_print
        print('[GeminiTTS] $model → inlineData vide');
        return null;
      }

      final pcm = base64Decode(data);
      final rate = sampleRateFromMimeType(inlineData?['mimeType'] as String?);
      final wav = pcm16ToWav(Uint8List.fromList(pcm), sampleRate: rate);

      // ignore: avoid_print
      print('[GeminiTTS] $model → ${wav.length} octets WAV @ $rate Hz');
      return TtsAudio(wav, 'wav');
    } catch (e) {
      // ignore: avoid_print
      print('[GeminiTTS] $model → erreur: $e');
      return null;
    }
  }

  /// Extrait la première partie du premier candidat, ou null si la forme
  /// de la réponse n'est pas celle attendue.
  Map<String, dynamic>? _firstPart(Map<String, dynamic> json) {
    final candidates = json['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) return null;
    final content = (candidates.first as Map)['content'] as Map?;
    final parts = content?['parts'] as List?;
    if (parts == null || parts.isEmpty) return null;
    return parts.first as Map<String, dynamic>;
  }

  String _resolveVoice() {
    final saved = SettingsService().ttsVoice;
    return voices.containsKey(saved) ? saved : defaultVoice;
  }

  String _truncate(String s) => s.length <= 200 ? s : '${s.substring(0, 200)}…';
}
