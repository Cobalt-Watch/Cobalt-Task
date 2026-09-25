import 'dart:typed_data';

import 'package:cobalt_task/services/tts/tts_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Gemini rend du PCM brut : si l'en-tête WAV est faux, Android joue un
/// silence ou refuse le fichier, et le repli local ne se déclenche même pas
/// puisque la synthèse, elle, a réussi. D'où ces vérifications au niveau octet.
void main() {
  group('pcm16ToWav', () {
    final pcm = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);

    int u32(Uint8List b, int offset) =>
        ByteData.view(b.buffer).getUint32(offset, Endian.little);
    int u16(Uint8List b, int offset) =>
        ByteData.view(b.buffer).getUint16(offset, Endian.little);
    String ascii(Uint8List b, int offset) =>
        String.fromCharCodes(b.sublist(offset, offset + 4));

    test('ajoute un en-tête de 44 octets devant les données', () {
      final wav = pcm16ToWav(pcm);
      expect(wav.length, 44 + pcm.length);
      expect(wav.sublist(44), pcm);
    });

    test('écrit les marqueurs RIFF/WAVE/fmt/data', () {
      final wav = pcm16ToWav(pcm);
      expect(ascii(wav, 0), 'RIFF');
      expect(ascii(wav, 8), 'WAVE');
      expect(ascii(wav, 12), 'fmt ');
      expect(ascii(wav, 36), 'data');
    });

    test('déclare les bonnes tailles de chunk', () {
      final wav = pcm16ToWav(pcm);
      expect(u32(wav, 4), 36 + pcm.length, reason: 'taille RIFF = total - 8');
      expect(u32(wav, 16), 16, reason: 'taille du chunk fmt');
      expect(u32(wav, 40), pcm.length, reason: 'taille du chunk data');
    });

    test('décrit du PCM 16 bits mono 24 kHz par défaut', () {
      final wav = pcm16ToWav(pcm);
      expect(u16(wav, 20), 1, reason: 'format PCM');
      expect(u16(wav, 22), 1, reason: 'canaux');
      expect(u32(wav, 24), 24000, reason: 'échantillonnage');
      expect(u32(wav, 28), 48000, reason: 'byte rate = 24000 * 1 * 2');
      expect(u16(wav, 32), 2, reason: 'block align');
      expect(u16(wav, 34), 16, reason: 'bits par échantillon');
    });

    test('recalcule byte rate et block align en stéréo', () {
      final wav = pcm16ToWav(pcm, sampleRate: 16000, channels: 2);
      expect(u32(wav, 24), 16000);
      expect(u32(wav, 28), 64000, reason: '16000 * 2 canaux * 2 octets');
      expect(u16(wav, 32), 4);
    });

    test('accepte un PCM vide sans casser l\'en-tête', () {
      final wav = pcm16ToWav(Uint8List(0));
      expect(wav.length, 44);
      expect(u32(wav, 40), 0);
    });
  });

  group('sampleRateFromMimeType', () {
    test('lit le paramètre rate de Gemini', () {
      expect(
        sampleRateFromMimeType('audio/L16;codec=pcm;rate=24000'),
        24000,
      );
      expect(sampleRateFromMimeType('audio/L16;codec=pcm;rate=16000'), 16000);
    });

    test('retombe sur 24000 quand le rate est absent ou illisible', () {
      expect(sampleRateFromMimeType(null), 24000);
      expect(sampleRateFromMimeType('audio/L16;codec=pcm'), 24000);
      expect(sampleRateFromMimeType('audio/wav'), 24000);
    });

    test('respecte le repli demandé', () {
      expect(sampleRateFromMimeType(null, fallback: 48000), 48000);
    });
  });
}
