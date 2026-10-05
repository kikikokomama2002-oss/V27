import 'package:flutter/material.dart';
import '../../playback/player_channel.dart';

/// Functional Equalizer screen: per-band sliders, built-in presets, and
/// bass boost, all wired to `android.media.audiofx.Equalizer`/`BassBoost`
/// via `PlayerChannel` (see `EqualizerController.kt` on the native side).
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
    // This screen owns the initial getEqualizerState() wait. The native
    // controller exposes cancellation specifically so a disposed screen does
    // not keep a bounded retry alive until its timeout. The native waiter is
    // shared per player and cancellation is safe because the Dart UI has only
    // one active owner in this screen flow.
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
      } catch (_) {
        // A newer mutation may already be authoritative; never overwrite it.
      }
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
    return Scaffold(
      appBar: AppBar(title: const Text('Equalizer')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final state = _state ?? {};
    final supported = state['supported'] as bool? ?? false;
    if (!supported) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            "This device doesn't support audio equalization, or nothing is loaded in the player yet.",
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final bands = (state['bands'] as List? ?? []).cast<Map>();
    final presets = (state['presets'] as List? ?? []).cast<Map>();
    final enabled = state['enabled'] as bool? ?? true;
    final bassBoostSupported = state['bassBoostSupported'] as bool? ?? false;
    final bassBoostStrength = (state['bassBoostStrength'] as num?)?.toInt() ?? 0;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          title: const Text('Equalizer enabled'),
          value: enabled,
          onChanged: _onEnabledChanged,
        ),
        if (presets.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Presets', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in presets)
                ActionChip(
                  label: Text(preset['name'] as String? ?? '—'),
                  onPressed: enabled
                      ? () => _onPresetSelected(preset['index'] as int)
                      : null,
                ),
            ],
          ),
        ],
        const SizedBox(height: 24),
        Text('Bands', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SizedBox(
          height: 260,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final band in bands)
                _BandSlider(
                  band: band,
                  enabled: enabled,
                  onChanged: (level) => _onBandChanged(band['index'] as int, level),
                ),
            ],
          ),
        ),
        if (bassBoostSupported) ...[
          const SizedBox(height: 24),
          Text('Bass Boost', style: Theme.of(context).textTheme.titleMedium),
          Slider(
            min: 0,
            max: 1000,
            value: bassBoostStrength.toDouble().clamp(0.0, 1000.0).toDouble(),
            label: '${(bassBoostStrength / 10).round()}%',
            onChanged: enabled
                ? (v) => _onBassBoostChanged(v.round())
                : null,
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
    final level = (band['levelMillibel'] as num).toDouble().clamp(min, max).toDouble();
    final freqHz = band['centerFreqHz'] as int? ?? 0;
    final freqLabel =
        freqHz >= 1000 ? '${(freqHz / 1000).toStringAsFixed(freqHz % 1000 == 0 ? 0 : 1)}k' : '$freqHz';

    return Column(
      children: [
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: Slider(
              min: min,
              max: max,
              value: level,
              onChanged: enabled ? (v) => onChanged(v.round()) : null,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text('${freqLabel}Hz', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
