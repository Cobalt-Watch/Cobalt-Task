import 'dart:typed_data';

/// =============================================================================
/// tts_engine.dart
/// =============================================================================
/// Interface commune aux moteurs de synthèse vocale distants (cloud).
///
/// Le moteur local (`flutter_tts`) n'implémente pas cette interface : il reste
/// le repli hors-ligne géré directement par AudioFeedbackService. Un moteur
/// cloud, lui, rend des octets audio que l'app joue elle-même.
///
/// Pour ajouter un fournisseur : implémenter cette interface, puis l'enregistrer
/// dans TtsEngineFactory (une ligne).
/// =============================================================================

/// Résultat d'une synthèse : les octets audio et leur extension de fichier.
class TtsAudio {
  /// Fichier audio complet, prêt à être joué (WAV, MP3...).
  final Uint8List bytes;

  /// Extension sans le point ('wav', 'mp3'). Sert au cache disque et au lecteur.
  final String extension;

  const TtsAudio(this.bytes, this.extension);
}

abstract class TtsEngine {
  /// Identifiant stable, stocké dans les préférences ('gemini', 'elevenlabs').
  String get id;

  /// Nom affiché dans les réglages.
  String get displayName;

  /// False si la clé API manque : AudioFeedbackService repliera sur le local.
  bool get isConfigured;

  /// Synthétise [text] et rend le fichier audio, ou null en cas d'échec.
  ///
  /// Ne doit jamais lever : un échec réseau doit rendre null pour laisser le
  /// repli local prendre la main sans casser le retour vocal.
  Future<TtsAudio?> synthesize(String text, {String locale = 'fr-FR'});
}

/// Emballe du PCM 16 bits signé little-endian dans un conteneur WAV.
///
/// Gemini rend du PCM brut (24 kHz, mono, 16 bits) : sans en-tête, aucun
/// lecteur Android ne sait le jouer.
Uint8List pcm16ToWav(
  Uint8List pcm, {
  int sampleRate = 24000,
  int channels = 1,
}) {
  const headerSize = 44;
  const bitsPerSample = 16;
  final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final blockAlign = channels * bitsPerSample ~/ 8;

  final out = Uint8List(headerSize + pcm.length);
  final view = ByteData.view(out.buffer);

  void writeAscii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      out[offset + i] = s.codeUnitAt(i);
    }
  }

  writeAscii(0, 'RIFF');
  view.setUint32(4, 36 + pcm.length, Endian.little); // taille du fichier - 8
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  view.setUint32(16, 16, Endian.little); // taille du chunk fmt
  view.setUint16(20, 1, Endian.little); // format PCM
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, byteRate, Endian.little);
  view.setUint16(32, blockAlign, Endian.little);
  view.setUint16(34, bitsPerSample, Endian.little);
  writeAscii(36, 'data');
  view.setUint32(40, pcm.length, Endian.little);

  out.setRange(headerSize, headerSize + pcm.length, pcm);
  return out;
}

/// Extrait le taux d'échantillonnage d'un mimeType Gemini.
///
/// Exemple : 'audio/L16;codec=pcm;rate=24000' → 24000.
/// Rend [fallback] si le paramètre est absent ou illisible.
int sampleRateFromMimeType(String? mimeType, {int fallback = 24000}) {
  if (mimeType == null) return fallback;
  final match = RegExp(r'rate=(\d+)').firstMatch(mimeType);
  if (match == null) return fallback;
  return int.tryParse(match.group(1)!) ?? fallback;
}
