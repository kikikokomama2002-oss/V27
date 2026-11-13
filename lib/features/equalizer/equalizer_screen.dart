import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../core/localization.dart';
import '../../playback/player_channel.dart';

String _localizedPresetName(BuildContext context, String rawName) {
  final normalized = rawName.trim().toLowerCase().replaceAll('_', ' ').replaceAll('-', ' ');
  final key = switch (normalized) {
    'normal' => 'preset_normal',
    'classical' || 'classic' => 'preset_classical',
    'dance' => 'preset_dance',
    'flat' => 'preset_flat',
    'folk' => 'preset_folk',
    'heavy metal' => 'preset_heavy_metal',
    'hip hop' => 'preset_hip_hop',
    'jazz' => 'preset_jazz',
    'pop' => 'preset_pop',
    'rock' => 'preset_rock',
    _ => null,
  };
  return key == null ? rawName : V27Strings.of(context).text(key);
}

/// Functional Equalizer screen wired to Android Equalizer/BassBoost.
class EqualizerScreen extends StatefulWidget {
  const EqualizerScreen({super.key});

  @override
  State<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends State<EqualizerScreen> {
  Map<String, dynamic>? _state;
  bool _loading = true;
  String? _error;
  int _mutationGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    PlayerChannel.instance.cancelEqualizerWait().catchError((_) {});
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final state = await PlayerChannel.instance.getEqualizerState();
      if (!mounted) return;
      setState(() {
        _state = state;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = V27Strings.of(context).text('equalizer_load_error_detail');
        _loading = false;
      });
    }
  }

  Future<void> _onBandChanged(int band, int levelMillibel) async {
    final generation = ++_mutationGeneration;
    if (!mounted) return;
    setState(() {
      final bands = (_state?['bands'] as List?)?.cast<Map>() ?? [];
      for (final entry in bands) {
        if (entry['index'] == band) entry['levelMillibel'] = levelMillibel;
      }
    });
    try {
      await PlayerChannel.instance.setEqualizerBand(band, levelMillibel);
    } catch (_) {
      if (!mounted || generation != _mutationGeneration) return;
      try {
        final refreshed = await PlayerChannel.instance.getEqualizerState();
        if (mounted && generation == _mutationGeneration) {
          setState(() => _state = refreshed);
        }
      } catch (_) {}
    }
  }

  Future<void> _onPresetSelected(int preset) async {
    final generation = ++_mutationGeneration;
    try {
      final refreshed = await PlayerChannel.instance.setEqualizerPreset(preset);
      if (!mounted || generation != _mutationGeneration) return;
      setState(() => _state = refreshed);
    } catch (_) {
      if (!mounted || generation != _mutationGeneration) return;
      try {
        final refreshed = await PlayerChannel.instance.getEqualizerState();
        if (mounted && generation == _mutationGeneration) {
          setState(() => _state = refreshed);
        }
      } catch (_) {}
    }
  }

  Future<void> _onBassBoostChanged(int strength) async {
    final generation = ++_mutationGeneration;
    if (!mounted) return;
    setState(() => _state = {..._state ?? {}, 'bassBoostStrength': strength});
    try {
      await PlayerChannel.instance.setBassBoost(strength);
    } catch (_) {
      if (!mounted || generation != _mutationGeneration) return;
      try {
        final refreshed = await PlayerChannel.instance.getEqualizerState();
        if (mounted && generation == _mutationGeneration) {
          setState(() => _state = refreshed);
        }
      } catch (_) {}
    }
  }

  Future<void> _onEnabledChanged(bool enabled) async {
    final generation = ++_mutationGeneration;
    if (!mounted) return;
    setState(() => _state = {..._state ?? {}, 'enabled': enabled});
    try {
      await PlayerChannel.instance.setEqualizerEnabled(enabled);
    } catch (_) {
      if (!mounted || generation != _mutationGeneration) return;
      try {
        final refreshed = await PlayerChannel.instance.getEqualizerState();
        if (mounted && generation == _mutationGeneration) {
          setState(() => _state = refreshed);
        }
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: Text(V27Strings.of(context).text('equalizer')),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 18),
            child: Center(
              child: Icon(Icons.graphic_eq_rounded,
                  color: Theme.of(context).colorScheme.primary, size: 25),
            ),
          ),
        ],
      ),
      body: _buildBody(context, dark),
    );
  }

  Widget _buildBody(BuildContext context, bool dark) {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
          color: Theme.of(context).colorScheme.primary,
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _InfoPanel(
            icon: Icons.error_outline_rounded,
            title: V27Strings.of(context).text('could_not_load_equalizer'),
            message: _error ?? V27Strings.of(context).text('equalizer_load_error_detail'),
            action: FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(V27Strings.of(context).text('try_again')),
            ),
          ),
        ),
      );
    }

    final state = _state ?? {};
    final supported = state['supported'] as bool? ?? false;
    if (!supported) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _InfoPanel(
            icon: Icons.headphones_rounded,
            title: V27Strings.of(context).text('audio_effects_unavailable'),
            message: V27Strings.of(context).text('equalizer_unsupported_detail'),
          ),
        ),
      );
    }

    final bands = (state['bands'] as List? ?? []).cast<Map>();
    final presets = (state['presets'] as List? ?? []).cast<Map>();
    final enabled = state['enabled'] as bool? ?? true;
    final bassBoostSupported = state['bassBoostSupported'] as bool? ?? false;
    final bassBoostStrength =
        (state['bassBoostStrength'] as num?)?.toInt() ?? 0;

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 32),
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? [
                      V27Palette.midnight,
                      Color.lerp(Theme.of(context).colorScheme.primary, V27Palette.midnight, 0.72)!,
                    ]
                  : [
                      Color.lerp(Theme.of(context).colorScheme.primary, Colors.white, 0.84)!,
                      const Color(0xFFE9EEF2),
                    ],
            ),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(17),
                ),
                child: Icon(Icons.equalizer_rounded,
                    color: Theme.of(context).colorScheme.primary, size: 30),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      V27Strings.of(context).text('sound_control'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.7,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      V27Strings.of(context).text('shape_your_sound'),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      V27Strings.of(context).text(enabled ? 'your_equalizer_active' : 'equalizer_bypassed'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.color
                                ?.withValues(alpha: 0.7),
                          ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: enabled,
                activeThumbColor: Theme.of(context).colorScheme.primary,
                onChanged: _onEnabledChanged,
              ),
            ],
          ),
        ),
        const SizedBox(height: 26),
        _SectionHeading(
          title: V27Strings.of(context).text('presets'),
          subtitle: V27Strings.of(context).text('quick_sound_profiles'),
          trailing: '${presets.length} ${V27Strings.of(context).text('available')}',
        ),
        const SizedBox(height: 13),
        if (presets.isEmpty)
          _MutedMessage(V27Strings.of(context).text('no_presets'))
        else
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              for (final preset in presets)
                ActionChip(
                  label: Text(_localizedPresetName(context, preset['name'] as String? ?? '—')),
                  onPressed: enabled
                      ? () => _onPresetSelected(preset['index'] as int)
                      : null,
                  backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.10),
                  side: BorderSide(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25),
                  ),
                  labelStyle: TextStyle(
                    color: enabled
                        ? Theme.of(context).colorScheme.onSurface
                        : Theme.of(context).disabledColor,
                    fontWeight: FontWeight.w600,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 28),
        _SectionHeading(
          title: V27Strings.of(context).text('frequency_bands'),
          subtitle: V27Strings.of(context).text('fine_tune_frequency'),
          trailing: '${bands.length} ${V27Strings.of(context).text('bands')}',
        ),
        const SizedBox(height: 13),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 18, 12, 14),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Theme.of(context).dividerColor.withValues(alpha: 0.8),
            ),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _ScaleLabel(V27Strings.of(context).text('max')),
                  Text(
                    '0 dB',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  _ScaleLabel(V27Strings.of(context).text('max')),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 230,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final band in bands)
                      Expanded(
                        child: _BandSlider(
                          band: band,
                          enabled: enabled,
                          onChanged: (level) => _onBandChanged(
                            band['index'] as int,
                            level,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                V27Strings.of(context).text('frequency_hint'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).hintColor,
                    ),
              ),
            ],
          ),
        ),
        if (bassBoostSupported) ...[
          const SizedBox(height: 28),
          _SectionHeading(
            title: V27Strings.of(context).text('bass_boost'),
            subtitle: V27Strings.of(context).text('add_depth'),
            trailing: '${(bassBoostStrength / 10).round()}%',
          ),
          const SizedBox(height: 13),
          Container(
            padding: const EdgeInsets.fromLTRB(18, 17, 18, 12),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: Theme.of(context).dividerColor.withValues(alpha: 0.8),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.surround_sound_rounded,
                      color: Theme.of(context).colorScheme.primary),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        V27Strings.of(context).text('bass_intensity'),
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      Slider(
                        min: 0,
                        max: 1000,
                        value: bassBoostStrength
                            .toDouble()
                            .clamp(0.0, 1000.0)
                            .toDouble(),
                        activeColor: Theme.of(context).colorScheme.primary,
                        onChanged: enabled
                            ? (v) => _onBassBoostChanged(v.round())
                            : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _BandSlider extends StatelessWidget {
  const _BandSlider({
    required this.band,
    required this.enabled,
    required this.onChanged,
  });

  final Map band;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final min = (band['minMillibel'] as num).toDouble();
    final max = (band['maxMillibel'] as num).toDouble();
    final level =
        (band['levelMillibel'] as num).toDouble().clamp(min, max).toDouble();
    final freqHz = band['centerFreqHz'] as int? ?? 0;
    final freqLabel = freqHz >= 1000
        ? '${(freqHz / 1000).toStringAsFixed(freqHz % 1000 == 0 ? 0 : 1)}k'
        : '$freqHz';

    return Column(
      children: [
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: Slider(
              min: min,
              max: max,
              value: level,
              activeColor: Theme.of(context).colorScheme.primary,
              inactiveColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.18),
              onChanged: enabled ? (v) => onChanged(v.round()) : null,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${freqLabel}Hz',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
              ),
        ),
        const SizedBox(height: 3),
        Text(
          '${(level / 100).toStringAsFixed(1)}',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontSize: 10,
                color: Theme.of(context).hintColor,
              ),
        ),
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      letterSpacing: 1.4,
                      fontWeight: FontWeight.w900,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).hintColor,
                    ),
              ),
            ],
          ),
        ),
        if (trailing != null)
          Text(
            trailing!,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
          ),
      ],
    );
  }
}

class _ScaleLabel extends StatelessWidget {
  const _ScaleLabel(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    return Text(
      value,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).hintColor,
            fontSize: 9,
            letterSpacing: 1,
          ),
    );
  }
}

class _MutedMessage extends StatelessWidget {
  const _MutedMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).hintColor,
          ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(26),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 42, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          const SizedBox(height: 9),
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[
            const SizedBox(height: 18),
            action!,
          ],
        ],
      ),
    );
  }
}
