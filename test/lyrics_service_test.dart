// Testes do LyricsService (item 3.6): .lrc ao lado do áudio (mesma
// pasta, mesmo nome), letra embutida (ID3v2 USLT) e a ordem entre elas
// (sidecar vence). O leitor de tags é exercitado com frames SINTÉTICOS:
// v2.3/v2.4, encodings, flags e tag corrompida — nada de rede.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/services/lyrics_service.dart';
import 'package:audify/utils/id3_lyrics_reader.dart';
import 'package:audify/utils/lrc_parser.dart';

// ---------------------------------------------------------------------------
// Construção de tags ID3v2 de teste (bytes na mão).
// ---------------------------------------------------------------------------

List<int> _synchsafe(int v) => <int>[
  (v >> 21) & 0x7f,
  (v >> 14) & 0x7f,
  (v >> 7) & 0x7f,
  v & 0x7f,
];

List<int> _be32(int v) => <int>[
  (v >> 24) & 0xff,
  (v >> 16) & 0xff,
  (v >> 8) & 0xff,
  v & 0xff,
];

List<int> _utf16Le(String s) => <int>[
  for (final int u in s.codeUnits) ...<int>[u & 0xff, u >> 8],
];

List<int> _utf16Be(String s) => <int>[
  for (final int u in s.codeUnits) ...<int>[u >> 8, u & 0xff],
];

/// Frame USLT: encoding(1) + idioma(3) + descritor terminado + texto.
List<int> _usltFrame(
  String text, {
  int encoding = 0, // 0=latin1, 1=UTF-16+BOM, 2=UTF-16BE, 3=UTF-8
  String desc = '',
  int formatFlags = 0,
  int major = 3, // v2.4 guarda o tamanho do frame em synchsafe
}) {
  final List<int> payload = <int>[encoding, ...ascii.encode('eng')];
  switch (encoding) {
    case 1:
      payload.addAll(<int>[
        0xff,
        0xfe,
        ..._utf16Le(desc),
        0,
        0,
        0xff,
        0xfe,
        ..._utf16Le(text),
      ]);
    case 2:
      payload.addAll(<int>[..._utf16Be(desc), 0, 0, ..._utf16Be(text)]);
    case 3:
      payload.addAll(<int>[...utf8.encode(desc), 0, ...utf8.encode(text)]);
    default:
      payload.addAll(<int>[...latin1.encode(desc), 0, ...latin1.encode(text)]);
  }
  return <int>[
    ...ascii.encode('USLT'),
    ...(major == 4 ? _synchsafe(payload.length) : _be32(payload.length)),
    0,
    formatFlags,
    ...payload,
  ];
}

Uint8List _id3Tag({
  required List<int> frames,
  int major = 3,
  int tagFlags = 0,
}) => Uint8List.fromList(<int>[
  ...ascii.encode('ID3'),
  major,
  0,
  tagFlags,
  ..._synchsafe(frames.length),
  ...frames,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('readId3v2Usult (leitor de tag embutida)', () {
    test('lê USLT do ID3v2.3 em latin1', () {
      final Uint8List tag = _id3Tag(
        frames: _usltFrame('letra embutida', encoding: 0),
      );
      expect(readId3v2Usult(tag), 'letra embutida');
    });

    test('ID3v2.4: tamanho do frame em synchsafe', () {
      final Uint8List tag = _id3Tag(
        major: 4,
        frames: _usltFrame('v4 também', encoding: 0),
      );
      expect(readId3v2Usult(tag), 'v4 também');
    });

    test('UTF-16 com BOM little-endian (encoding 1)', () {
      final Uint8List tag = _id3Tag(
        frames: _usltFrame('olá música 🎵', encoding: 1),
      );
      expect(readId3v2Usult(tag), 'olá música 🎵');
    });

    test('UTF-16BE sem BOM (encoding 2)', () {
      final Uint8List tag = _id3Tag(frames: _usltFrame('cantada', encoding: 2));
      expect(readId3v2Usult(tag), 'cantada');
    });

    test('UTF-8 (encoding 3)', () {
      final Uint8List tag = _id3Tag(
        frames: _usltFrame('música com ç e ã', encoding: 3),
      );
      expect(readId3v2Usult(tag), 'música com ç e ã');
    });

    test('descritor diferente de vazio não engole o texto', () {
      final Uint8List tag = _id3Tag(
        frames: _usltFrame('texto', encoding: 0, desc: 'letra'),
      );
      expect(readId3v2Usult(tag), 'texto');
    });

    test('primeiro USLT VAZIO não fecha: pega o seguinte', () {
      final Uint8List tag = _id3Tag(
        frames: <int>[
          ..._usltFrame('', encoding: 0),
          ..._usltFrame('outra', encoding: 0),
        ],
      );
      expect(readId3v2Usult(tag), 'outra');
    });

    test('tag com unsynchronisation no header é ignorada', () {
      final Uint8List tag = _id3Tag(
        frames: _usltFrame('x', encoding: 0),
        tagFlags: 0x20,
      );
      expect(readId3v2Usult(tag), isNull);
    });

    test('extended header e footer também são ignorados', () {
      for (final int flag in <int>[0x40, 0x10]) {
        final Uint8List tag = _id3Tag(
          frames: _usltFrame('x', encoding: 0),
          tagFlags: flag,
        );
        expect(
          readId3v2Usult(tag),
          isNull,
          reason: 'flag 0x${flag.toRadixString(16)}',
        );
      }
    });

    test('frame com flag de formato não é interpretado', () {
      final Uint8List tag = _id3Tag(
        frames: _usltFrame('x', encoding: 0, formatFlags: 0x01),
      );
      expect(readId3v2Usult(tag), isNull);
    });

    test('versão 2.2 e bytes sem ID3 devolvem null', () {
      final Uint8List v22 = _id3Tag(
        major: 2,
        frames: _usltFrame('x', encoding: 0),
      );
      expect(readId3v2Usult(v22), isNull);
      expect(readId3v2Usult(Uint8List.fromList(<int>[1, 2, 3, 4])), isNull);
      expect(readId3v2Usult(Uint8List(0)), isNull);
    });

    test('descritor sem terminador: não arrisca leitura torta', () {
      // encoding 0, idioma + texto SEM byte nulo de fim do descritor.
      final Uint8List tag = _id3Tag(
        frames: <int>[
          ...ascii.encode('USLT'),
          ..._be32(12), // encoding(1) + idioma(3) + 'semFim00'(8)
          0,
          0,
          0,
          ...ascii.encode('eng'),
          ...ascii.encode('semFim00'),
        ],
      );
      expect(readId3v2Usult(tag), isNull);
    });

    test('tag truncada/corrompida não lança', () {
      final Uint8List tag = _id3Tag(
        frames: _usltFrame('uma letra qualquer', encoding: 0),
      );
      expect(() => readId3v2Usult(tag.sublist(0, 14)), returnsNormally);
      expect(readId3v2Usult(tag.sublist(0, 14)), isNull);
      // Ids com bytes ilegais param o loop sem estourar.
      final Uint8List junk = Uint8List.fromList(<int>[
        ...ascii.encode('ID3'),
        3,
        0,
        0,
        ..._synchsafe(20),
        ...List<int>.filled(20, 0x80),
      ]);
      expect(() => readId3v2Usult(junk), returnsNormally);
    });
  });

  group('LyricsService — .lrc ao lado do áudio', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('audify_lyrics');
      LyricsService.clearCache();
    });

    tearDown(() {
      LyricsService.clearCache();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Song fileSong(String name) => Song.fromStored(<String, Object?>{
      'song_id': '${dir.path}/$name',
      'title': 'Faixa',
      'file_path': '${dir.path}/$name',
      'is_asset': 0,
    })!;

    test('lê o .lrc de mesmo nome na mesma pasta (sincronizado)', () async {
      File(
        '${dir.path}/song.mp3',
      ).writeAsBytesSync(<int>[1, 2, 3, 4]); // sem tag
      File('${dir.path}/song.lrc').writeAsStringSync(
        '[ti:Faixa]\n'
        '[00:01.00]linha um\n'
        '[00:02.50]linha dois',
      );

      final LrcLyrics? lyrics = await LyricsService.forSong(
        fileSong('song.mp3'),
      );

      expect(lyrics, isNotNull);
      expect(lyrics!.synced, isTrue);
      expect(lyrics.lines.map((LrcLine l) => l.text).toList(), <String>[
        'linha um',
        'linha dois',
      ]);
    });

    test('sidecar VENCE a letra embutida', () async {
      final File mp3 = File('${dir.path}/both.mp3');
      mp3.writeAsBytesSync(
        _id3Tag(frames: _usltFrame('embutida', encoding: 0)),
      );
      File(
        '${dir.path}/both.lrc',
      ).writeAsStringSync('[00:03.00]do arquivo lrc');

      final LrcLyrics? lyrics = await LyricsService.forSong(
        fileSong('both.mp3'),
      );

      expect(lyrics!.synced, isTrue);
      expect(lyrics.lines.single.text, 'do arquivo lrc');
    });

    test('sem sidecar: usa a embutida (texto corrido, sem destaque)', () async {
      final File mp3 = File('${dir.path}/plain.mp3');
      mp3.writeAsBytesSync(
        _id3Tag(frames: _usltFrame('primeira\nsegunda', encoding: 0)),
      );

      final LrcLyrics? lyrics = await LyricsService.forSong(
        fileSong('plain.mp3'),
      );

      expect(lyrics, isNotNull);
      expect(lyrics!.synced, isFalse);
      expect(lyrics.lines.map((LrcLine l) => l.text).toList(), <String>[
        'primeira',
        'segunda',
      ]);
    });

    test('sidecar SEM timestamps não bloqueia a tentativa embutida', () async {
      final File mp3 = File('${dir.path}/mix.mp3');
      mp3.writeAsBytesSync(_id3Tag(frames: _usltFrame('da tag', encoding: 0)));
      // .lrc inválido: nenhuma linha com tempo.
      File('${dir.path}/mix.lrc').writeAsStringSync('só texto, sem marcação');

      final LrcLyrics? lyrics = await LyricsService.forSong(
        fileSong('mix.mp3'),
      );

      expect(lyrics!.synced, isFalse);
      expect(lyrics.lines.single.text, 'da tag');
    });

    test('MP3 com USLT já em formato LRC sincroniza', () async {
      final File mp3 = File('${dir.path}/synced.mp3');
      mp3.writeAsBytesSync(
        _id3Tag(
          frames: _usltFrame('[00:01.00]linha\n[00:02.00]outra', encoding: 0),
        ),
      );

      final LrcLyrics? lyrics = await LyricsService.forSong(
        fileSong('synced.mp3'),
      );

      expect(lyrics!.synced, isTrue);
      expect(lyrics.lines, hasLength(2));
    });

    test('sem sidecar e sem tag legível: null', () async {
      File('${dir.path}/bare.mp3').writeAsBytesSync(<int>[9, 9, 9, 9]);
      expect(await LyricsService.forSong(fileSong('bare.mp3')), isNull);
    });

    test('faixa de asset sem .lrc empacotado devolve null', () async {
      final Song asset = Song.fromAsset(
        assetPath: 'assets/songs/sem_letra.mp3',
      );
      expect(await LyricsService.forSong(asset), isNull);
    });
  });
}
