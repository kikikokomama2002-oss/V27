import 'dart:async';
import 'package:flutter/material.dart';
import '../../playback/player_channel.dart';
import '../localization.dart';

/// Controls the one native sleep-timer deadline also used by Settings.
Future<void> showSleepTimerSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Theme.of(context).colorScheme.surface,
  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
  builder: (_) => const _SleepTimerSheet(),
);

class _SleepTimerSheet extends StatefulWidget {
  const _SleepTimerSheet();
  @override
  State<_SleepTimerSheet> createState() => _SleepTimerSheetState();
}

class _SleepTimerSheetState extends State<_SleepTimerSheet> {
  static const _presets = [5, 10, 15, 30, 45, 60];
  Timer? _ticker;
  DateTime? _deadline;
  int _remaining = 0;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() { super.initState(); _refresh(); }

  Future<void> _refresh() async {
    try {
      final ms = await PlayerChannel.instance.getSleepTimerDeadline();
      if (!mounted) return;
      _deadline = ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
      _tick();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _tick() {
    _ticker?.cancel();
    final deadline = _deadline;
    final seconds = deadline == null ? 0 : deadline.difference(DateTime.now()).inSeconds;
    if (mounted) setState(() { _remaining = seconds > 0 ? seconds : 0; _loading = false; });
    if (deadline != null && seconds > 0) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        final left = deadline.difference(DateTime.now()).inSeconds;
        if (!mounted) return;
        setState(() => _remaining = left > 0 ? left : 0);
        if (left <= 0) { _ticker?.cancel(); _deadline = null; }
      });
    }
  }

  Future<void> _start(int minutes) async {
    setState(() => _busy = true);
    final deadline = DateTime.now().add(Duration(minutes: minutes));
    try {
      await PlayerChannel.instance.setSleepTimerDeadline(deadline.millisecondsSinceEpoch);
      if (!mounted) return;
      _deadline = deadline;
      _tick();
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(V27Strings.of(context).text('could_not_start_timer'))));
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _cancel() async {
    setState(() => _busy = true);
    try {
      await PlayerChannel.instance.cancelSleepTimer();
      _ticker?.cancel();
      if (mounted) setState(() { _deadline = null; _remaining = 0; });
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(V27Strings.of(context).text('could_not_cancel_timer'))));
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _showCustomDuration() async {
    final controller = TextEditingController(text: '20');
    try {
      final strings = V27Strings.of(context);
      final value = await showDialog<int>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(strings.text('custom_duration')),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(suffixText: strings.text('minutes')),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(strings.text('cancel')),
            ),
            FilledButton(
              onPressed: () {
                final minutes = int.tryParse(controller.text);
                if (minutes != null && minutes > 0 && minutes <= 1440) {
                  Navigator.pop(dialogContext, minutes);
                }
              },
              child: Text(strings.text('start')),
            ),
          ],
        ),
      );
      if (value != null && mounted) await _start(value);
    } finally {
      controller.dispose();
    }
  }

  String get _clock => '${(_remaining ~/ 60).toString().padLeft(2, '0')}:${(_remaining % 60).toString().padLeft(2, '0')}';
  @override
  void dispose() { _ticker?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = V27Strings.of(context);
    return SafeArea(child: Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 38, height: 4, decoration: BoxDecoration(color: theme.colorScheme.outlineVariant, borderRadius: BorderRadius.circular(4)))),
        const SizedBox(height: 20),
        Row(children: [Icon(Icons.bedtime_rounded, color: theme.colorScheme.primary, size: 26), const SizedBox(width: 12), Text(strings.text('sleep_timer'), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))]),
        const SizedBox(height: 8),
        Text(_loading ? strings.text('checking_timer') : _deadline == null ? strings.text('stop_after') : '${strings.text('timer_stops_in')} $_clock', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 18),
        Wrap(spacing: 9, runSpacing: 9, children: _presets.map((m) => ActionChip(label: Text('$m min'), onPressed: _busy ? null : () => _start(m))).toList()),
        const SizedBox(height: 10),
        Row(children: [Expanded(child: OutlinedButton.icon(onPressed: _busy ? null : _showCustomDuration, icon: const Icon(Icons.edit_outlined), label: Text(strings.text('custom_duration')))),
          if (_deadline != null) ...[const SizedBox(width: 10), Expanded(child: FilledButton.tonalIcon(onPressed: _busy ? null : _cancel, icon: const Icon(Icons.close_rounded), label: Text(strings.text('cancel_timer'))))],
        ]),
      ]),
    ));
  }
}
