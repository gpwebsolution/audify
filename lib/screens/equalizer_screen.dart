import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/equalizer_provider.dart';
import '../providers/settings_provider.dart';
import '../services/audio_service.dart';

/// Item 3.3 — tela própria do equalizador: bandas (com a frequência real
/// lida no probe), presets, reforço de graves e o estado do aparelho.
///
/// A checagem de suporte é em RUNTIME: com o canal de plataforma
/// indisponível/sem efeito, a tela mostra o estado desligado com
/// mensagem amigável — nenhum caminho aqui propaga exceção.
class EqualizerScreen extends StatefulWidget {
  const EqualizerScreen({super.key});

  @override
  State<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends State<EqualizerScreen> {
  @override
  void initState() {
    super.initState();
    // Probe do suporte fora do build (canal nativo): se o player nunca
    // tocou nada, o serviço ativa a plataforma sozinho e limpa a fonte.
    // Sob FakeAsync (testWidgets) o EqualizerProvider curto-circuita no
    // override de teste e nenhum canal é tocado.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(context.read<EqualizerProvider>().probe());
    });
  }

  @override
  Widget build(BuildContext context) {
    final EqualizerProvider eq = context.watch<EqualizerProvider>();
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Equalizador')),
      body: eq.support == EqualizerSupport.unsupported
          ? _UnsupportedView(colors: colors)
          : _ControlsView(eq: eq, colors: colors),
    );
  }
}

/// Estado do aparelho sem suporte — controles desligados, sem crash.
class _UnsupportedView extends StatelessWidget {
  const _UnsupportedView({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.equalizer, size: 72, color: colors.outlineVariant),
            const SizedBox(height: 16),
            Text(
              'Equalizador indisponível',
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Este aparelho não expõe o efeito de equalizador '
              '(checado em runtime). A reprodução segue normal — '
              'apenas estes controles ficam desligados.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Controles: mestre, presets, reforço de graves e as bandas.
class _ControlsView extends StatelessWidget {
  const _ControlsView({required this.eq, required this.colors});

  final EqualizerProvider eq;
  final ColorScheme colors;

  static const String _headerTitle = 'Presets';

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool checking = eq.support == EqualizerSupport.unknown && eq.enabled;

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: <Widget>[
        // ---- Mestre ----
        SwitchListTile(
          secondary: const Icon(Icons.equalizer),
          title: const Text('Equalizador'),
          subtitle: checking
              ? const Text('Verificando suporte no aparelho…')
              : const Text('Aplica bandas, presets e graves a tudo.'),
          value: eq.enabled,
          onChanged: eq.setEqualizerEnabled,
        ),
        if (checking) const LinearProgressIndicator(minHeight: 2),
        if (!eq.enabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Ligue para ajustar as bandas, escolher um preset '
              'ou reforçar os graves.',
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),

        if (eq.enabled) ...<Widget>[
          // ---- Presets ----
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  _headerTitle,
                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: <Widget>[
                    for (final String name in EqualizerProvider.presets.keys)
                      ChoiceChip(
                        label: Text(name),
                        selected: eq.preset == name,
                        onSelected: (_) => unawaited(eq.applyPreset(name)),
                      ),
                    if (eq.preset == SettingsProvider.equalizerCustomPreset)
                      const _CustomPresetChip(),
                  ],
                ),
              ],
            ),
          ),

          // ---- Reforço de graves ----
          SwitchListTile(
            secondary: const Icon(Icons.graphic_eq),
            title: const Text('Reforço de graves'),
            subtitle: const Text('Soma ganho às duas bandas mais graves.'),
            value: eq.bassEnabled,
            onChanged: eq.setBassEnabled,
          ),
          if (eq.bassEnabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Row(
                children: <Widget>[
                  Text('Força: ${eq.bassStrength}%', style: text.bodyMedium),
                  Expanded(
                    child: Slider(
                      value: eq.bassStrength.toDouble(),
                      min: 0,
                      max: 100,
                      divisions: 20,
                      label: '${eq.bassStrength}%',
                      onChanged: (double v) =>
                          unawaited(eq.setBassStrength(v.round())),
                    ),
                  ),
                ],
              ),
            ),

          // ---- Bandas ----
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Bandas',
                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  'Cada deslizante vale de -15 a +15 dB.',
                  style: text.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                SizedBox(
                  height: 190,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      for (int i = 0; i < eq.bandCount; i++)
                        Expanded(
                          child: _BandColumn(eq: eq, index: i, colors: colors),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ---- Redefinir ----
          Center(
            child: TextButton.icon(
              onPressed: eq.reset,
              icon: const Icon(Icons.refresh),
              label: const Text('Redefinir'),
            ),
          ),
        ],
      ],
    );
  }
}

/// Chip exibido quando o usuário mexeu nas bandas na mão (não re-aplica
/// curva — só sinaliza o estado "Personalizado").
class _CustomPresetChip extends StatelessWidget {
  const _CustomPresetChip();

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: const Text(SettingsProvider.equalizerCustomPreset),
      selected: true,
      onSelected: (_) {},
    );
  }
}

/// Uma banda: ganho em dB, slider vertical e a frequência (real após o
/// probe; canônica enquanto o aparelho não responde).
class _BandColumn extends StatelessWidget {
  const _BandColumn({
    required this.eq,
    required this.index,
    required this.colors,
  });

  final EqualizerProvider eq;
  final int index;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final double value = eq.bandValue(index);
    final double? frequency = eq.bandFrequency(index);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          _dbLabel(value),
          style: text.labelSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: value > 0 ? colors.primary : colors.onSurfaceVariant,
          ),
        ),
        SizedBox(
          height: 140,
          child: RotatedBox(
            quarterTurns: -90,
            child: Slider(
              value: value.clamp(
                SettingsProvider.equalizerMinDb,
                SettingsProvider.equalizerMaxDb,
              ),
              min: SettingsProvider.equalizerMinDb,
              max: SettingsProvider.equalizerMaxDb,
              divisions: 30,
              onChanged: (double v) => unawaited(eq.setBand(index, v)),
            ),
          ),
        ),
        Text(
          frequency == null ? '—' : _freqLabel(frequency),
          style: text.labelSmall?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
  }

  /// Rótulo em pt-BR: '+6,5 dB' / '-3,0 dB' / '0,0 dB'.
  static String _dbLabel(double value) {
    final String number = value.toStringAsFixed(1).replaceAll('.', ',');
    return value > 0 ? '+$number dB' : '$number dB';
  }

  /// '60 Hz' / '3,6 kHz' / '14 kHz'.
  static String _freqLabel(double hz) {
    if (hz >= 1000) {
      final double k = hz / 1000;
      final String number =
          (k == k.roundToDouble() ? k.round().toString() : k.toStringAsFixed(1))
              .replaceAll('.', ',');
      return '$number kHz';
    }
    return '${hz.round()} Hz';
  }
}
