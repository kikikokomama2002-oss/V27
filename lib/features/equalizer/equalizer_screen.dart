import 'package:flutter/material.dart';
import '../../core/theme.dart';
import '../../playback/player_channel.dart';

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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load equalizer: $e';
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
        title: const Text('Equalizer'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 18),
            child: Center(
              child: Icon(Icons.graphic_eq_rounded,
                  color: V27Palette.violet, size: 25),
            ),
          ),
        ],
      ),
      body: _buildBody(context, dark),
    );
  }

  Widget _buildBody(BuildContext context, bool dark) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: V27Palette.violet),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _InfoPanel(
            icon: Icons.error_outline_rounded,
            title: 'Could not load equalizer',
            message: _error!,
            action: FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
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
            title: 'Audio effects unavailable',
            message:
                "This device doesn't support audio equalization, or nothing is loaded in the player yet.",
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
                  ? const [Color(0xFF252044), Color(0xFF151D32)]
                  : const [Color(0xFFECE6FF), Color(0xFFF4F7FF)],
            ),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: V27Palette.violet.withValues(alpha: 0.25),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: V27Palette.violet.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(17),
                ),
                child: const Icon(Icons.equalizer_rounded,
                    color: V27Palette.violet, size: 30),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SOUND CONTROL',
                      style: TextStyle(
                        color: V27Palette.violet,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.7,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'Shape your sound',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      enabled ? 'Your equalizer is active' : 'Equalizer is bypassed',
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
                activeThumbColor: V27Palette.violet,
                onChanged: _onEnabledChanged,
              ),
            ],
          ),
        ),
        const SizedBox(height: 26),
        _SectionHeading(
          title: 'PRESETS',
          subtitle: 'Quick sound profiles',
          trailing: '${presets.length} available',
        ),
        const SizedBox(height: 13),
        if (presets.isEmpty)
          const _MutedMessage('No built-in presets available.')
        else
          Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              for (final preset in presets)
                ActionChip(
                  label: Text(preset['name'] as String? ?? '—'),
                  onPressed: enabled
                      ? () => _onPresetSelected(preset['index'] as int)
                      : null,
                  backgroundColor: V27Palette.violet.withValues(alpha: 0.10),
                  side: BorderSide(
                    color: V27Palette.violet.withValues(alpha: 0.25),
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
          title: 'FREQUENCY BANDS',
          subtitle: 'Fine-tune each frequency',
          trailing: '${bands.length} bands',
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
                  _ScaleLabel('MAX'),
                  Text(
                    '0 dB',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: V27Palette.cyan,
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  _ScaleLabel('MAX'),
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
                'Drag each slider to adjust its frequency level',
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
            title: 'BASS BOOST',
            subtitle: 'Add depth to low frequencies',
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
                    color: V27Palette.cyan.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.surround_sound_rounded,
                      color: V27Palette.cyan),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Bass intensity',
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
                        activeColor: V27Palette.cyan,
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
              activeColor: V27Palette.violet,
              inactiveColor: V27Palette.violet.withValues(alpha: 0.16),
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
                  color: V27Palette.violet,
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
          Icon(icon, size: 42, color: V27Palette.violet),
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
