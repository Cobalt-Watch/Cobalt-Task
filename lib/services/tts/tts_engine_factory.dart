import '../settings_service.dart';
import 'elevenlabs_tts_engine.dart';
import 'gemini_tts_engine.dart';
import 'tts_engine.dart';

/// =============================================================================
/// tts_engine_factory.dart
/// =============================================================================
/// Résout le moteur TTS cloud à partir du réglage `ttsProvider`.
///
/// Ajouter un fournisseur = une entrée dans [_engines] et une dans [providers].
/// =============================================================================

/// Identifiant du moteur local hors-ligne (flutter_tts), qui n'est pas un
/// TtsEngine : il est joué directement par AudioFeedbackService.
const String kTtsProviderLocal = 'local';

/// Libellés affichés dans les réglages, dans l'ordre.
const Map<String, String> ttsProviders = {
  kTtsProviderLocal: 'Local',
  'gemini': 'Gemini',
  'elevenlabs': 'ElevenLabs',
};

final Map<String, TtsEngine> _engines = {
  'gemini': GeminiTtsEngine(),
  'elevenlabs': ElevenLabsTtsEngine(),
};

/// Moteur cloud actif, ou null si le réglage est sur local / inconnu.
///
/// Ne vérifie pas la présence de la clé API : c'est AudioFeedbackService qui
/// teste `isConfigured` pour décider du repli.
TtsEngine? activeCloudEngine() => _engines[SettingsService().ttsProvider];

/// Moteur correspondant à un identifiant donné (pour les réglages / tests).
TtsEngine? cloudEngineById(String id) => _engines[id];
