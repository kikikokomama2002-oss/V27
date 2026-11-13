import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../playback/player_channel.dart';

import '../../core/theme_mode_provider.dart';
import '../../core/accent_color_provider.dart';
import '../../core/localization.dart';
import '../../core/theme.dart';
import '../../core/permissions.dart';
import '../../core/playlist_store.dart';
import '../../core/widgets/playlist_name_dialog.dart';
import '../../core/widgets/track_artwork.dart';
import '../../core/providers.dart';
import '../../data/db/track.dart';
import '../../playback/queue_spec.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  static const _speedPreferenceKey = 'v27_playback_speed_v1';
  static const _speeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  double _speed = 1.0;
  bool _speedLoaded = false;
  bool _skipSilence = false;
  bool _skipSilenceLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadSpeed();
    _loadSkipSilence();
  }

  Future<void> _loadSkipSilence() async {
    try {
      final enabled = await PlayerChannel.instance.getSkipSilenceEnabled();
      if (!mounted) return;
      setState(() {
        _skipSilence = enabled;
        _skipSilenceLoaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _skipSilenceLoaded = true);
    }
  }

  Future<void> _changeSkipSilence(bool enabled) async {
    final previous = _skipSilence;
    setState(() => _skipSilence = enabled);
    try {
      await PlayerChannel.instance.setSkipSilenceEnabled(enabled);
    } catch (_) {
      if (!mounted) return;
      setState(() => _skipSilence = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(V27Strings.of(context).text('could_not_change_silence'))),
      );
    }
  }

  Future<void> _loadSpeed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(_speedPreferenceKey) ?? 1.0;
      final speed = _speeds.reduce(
        (a, b) => (a - saved).abs() <= (b - saved).abs() ? a : b,
      );
      await PlayerChannel.instance.setPlaybackSpeed(speed);
      if (!mounted) return;
      setState(() {
        _speed = speed;
        _speedLoaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _speedLoaded = true);
    }
  }

  Future<void> _changeSpeed(double? value) async {
    if (value == null) return;
    final previous = _speed;
    setState(() => _speed = value);
    try {
      await PlayerChannel.instance.setPlaybackSpeed(value);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_speedPreferenceKey, value);
    } catch (_) {
      if (mounted) {
        setState(() => _speed = previous);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(V27Strings.of(context).text('could_not_change_speed'))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final strings = V27Strings.of(context);
    final isDark = ref.watch(themeModeProvider) == ThemeMode.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.text('settings')),
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [
                        V27Palette.midnight,
                        Color.lerp(Theme.of(context).colorScheme.primary, V27Palette.midnight, 0.72)!,
                      ]
                    : [
                        Color.lerp(Theme.of(context).colorScheme.primary, Colors.white, 0.84)!,
                        const Color(0xFFE9EEF2),
                      ],
              ),
              borderRadius: BorderRadius.circular(V27Radius.xl),
              border: Border.all(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.22),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(V27Radius.lg),
                  ),
                  child: Icon(
                    Icons.tune_rounded,
                    color: Theme.of(context).colorScheme.primary,
                    size: 30,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        V27Strings.of(context).text('make_it_yours'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        V27Strings.of(context).text('your_listening_space'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        V27Strings.of(context).text('fine_tune'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          _settingsSection(context, V27Strings.of(context).text('playback'), Icons.graphic_eq_rounded, [
            const _SleepTimerSetting(),
            ListTile(
              leading: const Icon(Icons.speed_rounded),
              title: Text(V27Strings.of(context).text('play_speed')),
              subtitle: Text(
                _speedLoaded ? '${_speed.toString()}x' : V27Strings.of(context).text('loading'),
              ),
              trailing: DropdownButton<double>(
                value: _speeds.contains(_speed) ? _speed : 1.0,
                onChanged: _speedLoaded ? _changeSpeed : null,
                items: _speeds.map((speed) {
                  return DropdownMenuItem<double>(
                    value: speed,
                    child: Text('${speed.toString()}x'),
                  );
                }).toList(),
              ),
            ),
            const _CrossfadeSetting(),
            SwitchListTile(
              secondary: const Icon(Icons.volume_down_outlined),
              title: Text(V27Strings.of(context).text('skip_silence')),
              subtitle: Text(
                V27Strings.of(context).text('skip_silence_description'),
              ),
              value: _skipSilence,
              onChanged: _skipSilenceLoaded ? _changeSkipSilence : null,
            ),
            _NativeSwitchSetting(
              icon: Icons.lock_outline_rounded,
              title: V27Strings.of(context).text('lock_screen_controls'),
              subtitle: V27Strings.of(context).text('lock_screen_controls_desc'),
              load: PlayerChannel.instance.getLockScreenControlsEnabled,
              save: PlayerChannel.instance.setLockScreenControlsEnabled,
            ),
          ]),

          _settingsSection(context, V27Strings.of(context).text('playlists'), Icons.queue_music_rounded, [
            const _QueueSettingsSetting(),
            const _AvoidDuplicateSongsSetting(),
            const _ManagePlaylistsSetting(),
          ]),

          _settingsSection(context, V27Strings.of(context).text('general'), Icons.settings_rounded, [
            Consumer(builder: (context, ref, _) {
              final selected = ref.watch(languageProvider);
              return ListTile(
                leading: const Icon(Icons.language_rounded),
                title: Text(strings.text('language')),
                subtitle: Text(strings.text('choose_language')),
                trailing: DropdownButton<String>(
                  value: selected,
                  onChanged: (value) { if (value != null) ref.read(languageProvider.notifier).select(value); },
                  items: v27Languages.map((item) => DropdownMenuItem(value: item.code, child: Text(item.name))).toList(),
                ),
              );
            }),
            Consumer(builder: (context, ref, _) {
              final selected = ref.watch(accentColorProvider);
              return ListTile(
                leading: const Icon(Icons.palette_outlined),
                title: Text(strings.text('accent_color')),
                subtitle: Text(strings.text('personalize_accent')),
                trailing: DropdownButton<String>(
                  value: selected,
                  onChanged: (value) { if (value != null) ref.read(accentColorProvider.notifier).select(value); },
                  items: accentOptions
                      .map(
                        (item) => DropdownMenuItem<String>(
                          value: item.id,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 14,
                                height: 14,
                                decoration: BoxDecoration(
                                  color: isDark ? item.darkColor : item.lightColor,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(V27Strings.of(context).text('accent_${item.id}')),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                ),
              );
            }),
            SwitchListTile(
              secondary: const Icon(Icons.dark_mode_outlined),
              title: Text(V27Strings.of(context).text('dark_mode')),
              subtitle: Text(V27Strings.of(context).text(isDark ? 'on' : 'off')),
              value: isDark,
              onChanged: (value) {
                ref.read(themeModeProvider.notifier).setDarkMode(value);
              },
            ),
            _NativeSwitchSetting(
              icon: Icons.devices_rounded,
              title: V27Strings.of(context).text('external_device_playback'),
              subtitle: V27Strings.of(context).text('external_device_playback_desc'),
              load: PlayerChannel.instance.getExternalDeviceStartEnabled,
              save: PlayerChannel.instance.setExternalDeviceStartEnabled,
            ),
          ]),

          _settingsSection(context, V27Strings.of(context).text('privacy'), Icons.shield_outlined, [
            const _PermissionsSetting(),
          ]),

          _settingsSection(context, V27Strings.of(context).text('about'), Icons.info_outline_rounded, [
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: Text(V27Strings.of(context).text('about')),
              subtitle: Text(V27Strings.of(context).text('app_version_info')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showAboutDialog(
                context: context,
                applicationName: 'V27',
                applicationVersion: '1.0.0+1',
                applicationLegalese: V27Strings.of(context).text('application_legalese'),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.mail_outline_rounded),
              title: Text(V27Strings.of(context).text('contact_us')),
              subtitle: Text(V27Strings.of(context).text('share_feedback')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () async {
                try {
                  await PlayerChannel.instance.openContactComposer();
                } catch (_) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(V27Strings.of(context).text('could_not_open_feedback')),
                    ),
                  );
                }
              },
            ),
          ]),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'V27 PULSE  •  ${V27Strings.of(context).text('brand_tagline')}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingsSection(
    BuildContext context,
    String title,
    IconData icon,
    List<Widget> children,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Row(
              children: [
                Icon(icon, size: 17, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 9),
                Text(
                  title.toUpperCase(),
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.6,
                      ),
                ),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: isDark ? V27Palette.darkSurface : Colors.white,
              borderRadius: BorderRadius.circular(21),
              border: Border.all(
                color: isDark
                    ? V27Palette.darkBorder
                    : V27Palette.lightBorder,
              ),
            ),
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      indent: 58,
                      endIndent: 16,
                      color: isDark
                          ? V27Palette.darkBorder
                          : V27Palette.lightBorder,
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

}

class _SleepTimerSetting extends StatefulWidget {
  const _SleepTimerSetting();

  @override
  State<_SleepTimerSetting> createState() => _SleepTimerSettingState();
}

class _SleepTimerSettingState extends State<_SleepTimerSetting> {
  static const _presets = <int>[5, 10, 15, 30, 45, 60];

  // The native playback service owns the actual deadline and pause callback.
  // This Dart timer only refreshes the visible countdown while this tile is
  // mounted, so leaving Settings no longer cancels the sleep timer.
  Timer? _ticker;
  DateTime? _deadline;
  int? _selectedMinutes;
  int _remainingSeconds = 0;
  bool _loading = true;

  bool get _active => _deadline != null;

  @override
  void initState() {
    super.initState();
    _loadSavedTimer();
  }

  Future<void> _loadSavedTimer() async {
    try {
      final deadlineMs = await PlayerChannel.instance.getSleepTimerDeadline();
      if (!mounted) return;
      if (deadlineMs == null) {
        setState(() {
          _deadline = null;
          _remainingSeconds = 0;
          _loading = false;
        });
        return;
      }
      final deadline = DateTime.fromMillisecondsSinceEpoch(deadlineMs);
      final remaining = deadline.difference(DateTime.now()).inSeconds;
      if (remaining <= 0) {
        setState(() {
          _deadline = null;
          _remainingSeconds = 0;
          _loading = false;
        });
        return;
      }
      _applyDeadline(deadline, selectedMinutes: null);
      if (mounted) setState(() => _loading = false);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applyDeadline(DateTime deadline, {required int? selectedMinutes}) {
    _ticker?.cancel();
    final remaining = deadline.difference(DateTime.now()).inSeconds;
    if (remaining <= 0) {
      setState(() {
        _deadline = null;
        _selectedMinutes = null;
        _remainingSeconds = 0;
        _loading = false;
      });
      return;
    }
    setState(() {
      _deadline = deadline;
      _selectedMinutes = selectedMinutes;
      _remainingSeconds = remaining;
      _loading = false;
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final activeDeadline = _deadline;
      if (activeDeadline == null) {
        _ticker?.cancel();
        return;
      }
      final nextRemaining = activeDeadline.difference(DateTime.now()).inSeconds;
      if (nextRemaining <= 0) {
        _ticker?.cancel();
        _ticker = null;
        if (mounted) {
          setState(() {
            _deadline = null;
            _selectedMinutes = null;
            _remainingSeconds = 0;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(V27Strings.of(context).text('sleep_timer_finished')),
            ),
          );
        }
      } else if (mounted) {
        setState(() => _remainingSeconds = nextRemaining);
      }
    });
  }

  Future<void> _startTimer(int minutes) async {
    final deadline = DateTime.now().add(Duration(minutes: minutes));
    try {
      await PlayerChannel.instance.setSleepTimerDeadline(
        deadline.millisecondsSinceEpoch,
      );
      if (!mounted) return;
      _applyDeadline(deadline, selectedMinutes: minutes);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(V27Strings.of(context).text('could_not_start_timer'))),
      );
    }
  }

  Future<void> _cancelTimer() async {
    try {
      await PlayerChannel.instance.cancelSleepTimer();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(V27Strings.of(context).text('could_not_cancel_timer'))),
        );
      }
      return;
    }
    _ticker?.cancel();
    _ticker = null;
    if (mounted) {
      setState(() {
        _deadline = null;
        _selectedMinutes = null;
        _remainingSeconds = 0;
      });
    }
  }

  Future<void> _chooseCustomDuration() async {
    final minutes = await showDialog<int>(
      context: context,
      builder: (_) => _CustomSleepTimerDialog(
        initialMinutes: _selectedMinutes ?? 20,
      ),
    );

    if (minutes != null && mounted) {
      await _startTimer(minutes);
    }
  }

  String get _remainingLabel {
    final minutes = _remainingSeconds ~/ 60;
    final seconds = _remainingSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')} ${V27Strings.of(context).text('remaining')}';
  }

  @override
  void dispose() {
    // Cancel only the UI ticker. The native deadline deliberately survives.
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.bedtime_outlined),
      title: Text(V27Strings.of(context).text('sleep_timer')),
      subtitle: Text(
        _loading
            ? V27Strings.of(context).text('loading_timer')
            : (_active ? _remainingLabel : V27Strings.of(context).text('stop_playback_set_time')),
      ),
      trailing: _active
          ? IconButton(
              tooltip: V27Strings.of(context).text('cancel_sleep_timer'),
              onPressed: _cancelTimer,
              icon: const Icon(Icons.close),
            )
          : const Icon(Icons.chevron_right),
      onTap: () async {
        final choice = await showModalBottomSheet<int>(
          context: context,
          builder: (sheetContext) => SafeArea(
            child: Wrap(
              children: [
                ListTile(title: Text(V27Strings.of(sheetContext).text('stop_playback_after'))),
                ..._presets.map(
                  (minutes) => ListTile(
                    leading: const Icon(Icons.timer_outlined),
                    title: Text('$minutes ${V27Strings.of(sheetContext).text('minutes')}'),
                    onTap: () => Navigator.pop(sheetContext, minutes),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: Text('${V27Strings.of(sheetContext).text('custom_duration')}…'),
                  onTap: () => Navigator.pop(sheetContext, -1),
                ),
                if (_active)
                  ListTile(
                    leading: const Icon(Icons.close),
                    title: Text(V27Strings.of(sheetContext).text('cancel_active_timer')),
                    onTap: () => Navigator.pop(sheetContext, 0),
                  ),
              ],
            ),
          ),
        );

        if (!mounted || choice == null) return;
        if (choice == -1) {
          await _chooseCustomDuration();
        } else if (choice == 0) {
          await _cancelTimer();
        } else {
          await _startTimer(choice);
        }
      },
    );
  }
}

class _PermissionsSetting extends StatelessWidget {
  const _PermissionsSetting();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.security_outlined),
      title: Text(V27Strings.of(context).text('app_permissions')),
      subtitle: Text(V27Strings.of(context).text('permissions_description')),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => const _PermissionsDialog(),
      ),
    );
  }
}

class _PermissionsDialog extends StatefulWidget {
  const _PermissionsDialog();

  @override
  State<_PermissionsDialog> createState() => _PermissionsDialogState();
}

class _PermissionsDialogState extends State<_PermissionsDialog> with WidgetsBindingObserver {
  String _audioStatus = 'checking';
  String _notificationStatus = 'checking';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String _describe(PermissionStatus status) {
    if (status.isGranted || status.isLimited) return 'allowed';
    if (status.isPermanentlyDenied || status.isRestricted) {
      return 'blocked_in_settings';
    }
    return 'not_granted';
  }

  Future<void> _refresh() async {
    try {
      final audio = await Permission.audio.status;
      final storage = await Permission.storage.status;
      final notifications = await Permission.notification.status;
      if (!mounted) return;
      setState(() {
        _audioStatus = _describe(audio.isGranted ? audio : storage);
        _notificationStatus = _describe(notifications);
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _audioStatus = 'could_not_read_status';
          _notificationStatus = 'could_not_read_status';
        });
      }
    }
  }

  Future<void> _request() async {
    setState(() => _busy = true);
    try {
      await PermissionsHelper.requestAudioPermission();
      await PermissionsHelper.requestNotificationPermission();
      await _refresh();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(V27Strings.of(context).text('could_not_request_permissions'))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(V27Strings.of(context).text('app_permissions')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.library_music_outlined),
            title: Text(V27Strings.of(context).text('music_library')),
            subtitle: Text(V27Strings.of(context).text(_audioStatus)),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.notifications_outlined),
            title: Text(V27Strings.of(context).text('notifications')),
            subtitle: Text(V27Strings.of(context).text(_notificationStatus)),
          ),
          const SizedBox(height: 4),
          Text(V27Strings.of(context).text('notification_optional')),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () async {
            try {
              await openAppSettings();
              if (mounted) await _refresh();
            } catch (_) {
              if (!mounted) return;
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                SnackBar(content: Text(V27Strings.of(context).text('could_not_open_system_settings'))),
              );
            }
          },
          child: Text(V27Strings.of(context).text('open_settings')),
        ),
        FilledButton(
          onPressed: _busy ? null : _request,
          child: Text(_busy ? V27Strings.of(context).text('checking') : V27Strings.of(context).text('request_permissions')),
        ),
      ],
    );
  }
}

typedef _BoolSettingLoader = Future<bool> Function();
typedef _BoolSettingSaver = Future<void> Function(bool value);

class _NativeSwitchSetting extends StatefulWidget {
  const _NativeSwitchSetting({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.load,
    required this.save,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final _BoolSettingLoader load;
  final _BoolSettingSaver save;

  @override
  State<_NativeSwitchSetting> createState() => _NativeSwitchSettingState();
}

class _NativeSwitchSettingState extends State<_NativeSwitchSetting> {
  bool _value = true;
  bool _loaded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await widget.load();
      if (!mounted) return;
      setState(() {
        _value = value;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _setValue(bool value) async {
    final previous = _value;
    setState(() {
      _value = value;
      _saving = true;
    });
    try {
      await widget.save(value);
    } catch (_) {
      if (!mounted) return;
      setState(() => _value = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${V27Strings.of(context).text('could_not_update_setting')} ${widget.title.toLowerCase()}.')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
    secondary: Icon(widget.icon),
    title: Text(widget.title),
    subtitle: Text(_saving ? V27Strings.of(context).text('saving') : widget.subtitle),
    value: _value,
    onChanged: _loaded && !_saving ? _setValue : null,
  );
}

class _CrossfadeSetting extends StatelessWidget {
  const _CrossfadeSetting();

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.shuffle),
    title: Text(V27Strings.of(context).text('crossfade')),
    subtitle: Text(V27Strings.of(context).text('crossfade_unavailable')),
    trailing: const Icon(Icons.info_outline),
    onTap: () => showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(V27Strings.of(context).text('crossfade_not_ready')),
        content: Text(V27Strings.of(context).text('crossfade_explanation')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(V27Strings.of(context).text('ok')),
          ),
        ],
      ),
    ),
  );
}

class _QueueSettingsSetting extends StatelessWidget {
  const _QueueSettingsSetting();

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.queue_music),
    title: Text(V27Strings.of(context).text('queue_settings')),
    subtitle: Text(V27Strings.of(context).text('repeat_description')),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const _QueueSettingsScreen()),
    ),
  );
}

class _QueueSettingsScreen extends StatefulWidget {
  const _QueueSettingsScreen();

  @override
  State<_QueueSettingsScreen> createState() => _QueueSettingsScreenState();
}

class _QueueSettingsScreenState extends State<_QueueSettingsScreen> {
  bool _repeatCurrent = false;
  bool _loaded = false;
  int _restartThreshold = 3;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await Future.wait<Object>([
        PlayerChannel.instance.getRepeatCurrentTrackEnabled(),
        PlayerChannel.instance.getPreviousRestartThresholdSeconds(),
      ]);
      if (!mounted) return;
      setState(() {
        _repeatCurrent = values[0] as bool;
        _restartThreshold = values[1] as int;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _setRepeatCurrent(bool enabled) async {
    final previous = _repeatCurrent;
    setState(() { _repeatCurrent = enabled; _saving = true; });
    try {
      await PlayerChannel.instance.setRepeatCurrentTrackEnabled(enabled);
    } catch (_) {
      if (!mounted) return;
      setState(() => _repeatCurrent = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(V27Strings.of(context).text('could_not_update_repeat'))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setRestartThreshold(int? seconds) async {
    if (seconds == null) return;
    final previous = _restartThreshold;
    setState(() { _restartThreshold = seconds; _saving = true; });
    try {
      await PlayerChannel.instance.setPreviousRestartThresholdSeconds(seconds);
    } catch (_) {
      if (!mounted) return;
      setState(() => _restartThreshold = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(V27Strings.of(context).text('could_not_update_previous'))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(V27Strings.of(context).text('queue_settings'))),
    body: ListView(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.repeat_one),
          title: Text(V27Strings.of(context).text('repeat_current')),
          subtitle: Text(V27Strings.of(context).text('repeat_description')),
          value: _repeatCurrent,
          onChanged: _loaded && !_saving ? _setRepeatCurrent : null,
        ),
        ListTile(
          leading: const Icon(Icons.skip_previous),
          title: Text(V27Strings.of(context).text('restart_previous')),
          subtitle: Text(V27Strings.of(context).text('previous_threshold')),
          trailing: DropdownButton<int>(
            value: const [0, 3, 5, 10].contains(_restartThreshold) ? _restartThreshold : 3,
            onChanged: _loaded && !_saving ? _setRestartThreshold : null,
            items: const [0, 3, 5, 10].map((seconds) => DropdownMenuItem<int>(
              value: seconds,
              child: Text('$seconds ${V27Strings.of(context).text('seconds_abbrev')}'),
            )).toList(),
          ),
        ),
      ],
    ),
  );
}

class _AvoidDuplicateSongsSetting extends ConsumerWidget {
  const _AvoidDuplicateSongsSetting();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playlistStoreProvider);
    return SwitchListTile(
      secondary: const Icon(Icons.library_add_check_outlined),
      title: Text(V27Strings.of(context).text('duplicate_songs')),
      subtitle: Text(V27Strings.of(context).text('duplicate_songs_description')),
      value: state.avoidDuplicateSongs,
      onChanged: state.isLoading
          ? null
          : (value) => ref.read(playlistStoreProvider.notifier).setAvoidDuplicateSongs(value),
    );
  }
}

class _ManagePlaylistsSetting extends StatelessWidget {
  const _ManagePlaylistsSetting();

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.playlist_play),
    title: Text(V27Strings.of(context).text('manage_playlists')),
    subtitle: Text(V27Strings.of(context).text('playlist_management_description')),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const _ManagePlaylistsScreen()),
    ),
  );
}

Future<String?> _showPlaylistNameDialog(
  BuildContext context, {
  String title = 'Create playlist',
  String initialValue = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => PlaylistNameDialog(
      title: title,
      initialValue: initialValue,
      submitLabel: 'Save',
    ),
  );
}

Future<void> _createPlaylistFromUi(BuildContext context, WidgetRef ref) async {
  final name = await _showPlaylistNameDialog(context);
  if (name == null || !context.mounted) return;
  final created = await ref.read(playlistStoreProvider.notifier).createPlaylist(name);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(created == null ? V27Strings.of(context).text('playlist_name_invalid') : V27Strings.of(context).text('playlist_created'))),
  );
}

class _ManagePlaylistsScreen extends ConsumerWidget {
  const _ManagePlaylistsScreen();

  // Curated cover identities stay varied; Teal remains the app accent,
  // rather than forcing every playlist tile into the same brand gradient.
  static const _gradients = <List<Color>>[
    [Color(0xFF168F91), Color(0xFF164B58)],
    [Color(0xFFE07852), Color(0xFF783D45)],
    [Color(0xFF4779C7), Color(0xFF263B70)],
    [Color(0xFF668B62), Color(0xFF294D43)],
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playlistStoreProvider);
    final store = ref.read(playlistStoreProvider.notifier);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(V27Strings.of(context).text('your_playlists')),
        actions: [
          IconButton(
            tooltip: V27Strings.of(context).text('create_playlist'),
            icon: const Icon(Icons.add_rounded),
            onPressed: state.isLoading
                ? null
                : () => _createPlaylistFromUi(context, ref),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: state.isLoading
          ? const Center(child: CircularProgressIndicator())
          : state.playlists.isEmpty
              ? _PlaylistEmptyState(
                  onCreate: () => _createPlaylistFromUi(context, ref),
                )
              : CustomScrollView(
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              V27Strings.of(context).text('your_collection'),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2.0,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              V27Strings.of(context).text('made_for_mood'),
                              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.7,
                                  ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              '${state.playlists.length} ${V27Strings.of(context).text('playlists')}  ·  ${state.playlists.fold<int>(0, (sum, item) => sum + item.songs.length)} ${V27Strings.of(context).text('songs_saved')}',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final playlist = state.playlists[index];
                            final colors = _gradients[index % _gradients.length];

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 13),
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(22),
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => _PlaylistDetailsScreen(
                                        playlistId: playlist.id,
                                      ),
                                    ),
                                  ),
                                  child: Ink(
                                    decoration: BoxDecoration(
                                      color: isDark
                                          ? V27Palette.darkSurface
                                          : Colors.white,
                                      borderRadius: BorderRadius.circular(22),
                                      border: Border.all(
                                        color: isDark
                                            ? V27Palette.darkBorder
                                            : V27Palette.lightBorder,
                                      ),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(13),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 68,
                                            height: 68,
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                                colors: colors,
                                              ),
                                              borderRadius: BorderRadius.circular(17),
                                            ),
                                            child: Stack(
                                              children: [
                                                Positioned(
                                                  right: -9,
                                                  bottom: -12,
                                                  child: Icon(
                                                    Icons.graphic_eq_rounded,
                                                    size: 55,
                                                    color: Colors.white.withValues(alpha: 0.13),
                                                  ),
                                                ),
                                                const Center(
                                                  child: Icon(
                                                    Icons.queue_music_rounded,
                                                    size: 31,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 14),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  playlist.name,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                                        fontWeight: FontWeight.w800,
                                                      ),
                                                ),
                                                const SizedBox(height: 6),
                                                Text(
                                                  '${playlist.songs.length} ${V27Strings.of(context).text(playlist.songs.length == 1 ? 'song' : 'songs')}',
                                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                                                      ),
                                                ),
                                                const SizedBox(height: 9),
                                                Container(
                                                  width: 34,
                                                  height: 3,
                                                  decoration: BoxDecoration(
                                                    color: colors.first,
                                                    borderRadius: BorderRadius.circular(4),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          PopupMenuButton<String>(
                                            tooltip: V27Strings.of(context).text('playlist_options'),
                                            icon: const Icon(Icons.more_vert_rounded),
                                            onSelected: (action) async {
                                              if (action == 'rename') {
                                                final name = await _showPlaylistNameDialog(
                                                  context,
                                                  title: V27Strings.of(context).text('rename_playlist'),
                                                  initialValue: playlist.name,
                                                );
                                                if (name == null || !context.mounted) return;
                                                final ok = await store.renamePlaylist(playlist.id, name);
                                                if (!context.mounted) return;
                                                if (!ok) {
                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                    SnackBar(
                                                      content: Text(V27Strings.of(context).text('playlist_name_invalid')),
                                                    ),
                                                  );
                                                }
                                              } else if (action == 'delete') {
                                                final confirm = await showDialog<bool>(
                                                  context: context,
                                                  builder: (dialogContext) => AlertDialog(
                                                    title: Text(V27Strings.of(context).text('delete_playlist_question')),
                                                    content: Text(
                                                      V27Strings.of(context).text('delete_playlist_confirm'),
                                                    ),
                                                    actions: [
                                                      TextButton(
                                                        onPressed: () => Navigator.pop(dialogContext, false),
                                                        child: Text(V27Strings.of(context).text('cancel')),
                                                      ),
                                                      FilledButton(
                                                        onPressed: () => Navigator.pop(dialogContext, true),
                                                        child: Text(V27Strings.of(context).text('delete')),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                                if (confirm == true) {
                                                  await store.deletePlaylist(playlist.id);
                                                }
                                              }
                                            },
                                            itemBuilder: (_) => [
                                              PopupMenuItem(
                                                value: 'rename',
                                                child: Row(
                                                  children: [
                                                    Icon(Icons.edit_outlined, size: 19),
                                                    SizedBox(width: 10),
                                                    Text(V27Strings.of(context).text('rename')),
                                                  ],
                                                ),
                                              ),
                                              PopupMenuItem(
                                                value: 'delete',
                                                child: Row(
                                                  children: [
                                                    Icon(Icons.delete_outline, size: 19),
                                                    SizedBox(width: 10),
                                                    Text(V27Strings.of(context).text('delete')),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                          childCount: state.playlists.length,
                        ),
                      ),
                    ),
                  ],
                ),
      floatingActionButton: state.isLoading || state.playlists.isEmpty
          ? null
          : FloatingActionButton(
              onPressed: () => _createPlaylistFromUi(context, ref),
              child: const Icon(Icons.add_rounded),
            ),
    );
  }
}

class _PlaylistEmptyState extends StatelessWidget {
  const _PlaylistEmptyState({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
              ),
              child: Icon(
                Icons.queue_music_rounded,
                size: 52,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 25),
            Text(
              V27Strings.of(context).text('your_music_your_way'),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 9),
            Text(
              V27Strings.of(context).text('create_playlist_empty_body'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded),
              label: Text(V27Strings.of(context).text('create_playlist')),
            ),
          ],
        ),
      ),
    );
  }
}


class _PlaylistDetailsScreen extends ConsumerWidget {
  const _PlaylistDetailsScreen({required this.playlistId});

  final String playlistId;

  String _formatDuration(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playlistStoreProvider);
    UserPlaylist? playlist;
    for (final item in state.playlists) {
      if (item.id == playlistId) {
        playlist = item;
        break;
      }
    }

    final repo = ref.watch(libraryRepositoryProvider);
    final currentPlaylist = playlist;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (currentPlaylist == null) {
      return Scaffold(
        appBar: AppBar(title: Text(V27Strings.of(context).text('playlist'))),
        body: Center(child: Text(V27Strings.of(context).text('playlist_missing'))),
      );
    }

    if (repo == null) {
      return Scaffold(
        appBar: AppBar(title: Text(currentPlaylist.name)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(currentPlaylist.name)),
      body: FutureBuilder<List<Track>>(
        future: repo.tracksForMediaStoreIdentities(
          currentPlaylist.songs
              .map((song) => (volume: song.volume, id: song.mediaStoreId))
              .toList(growable: false),
        ),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text(V27Strings.of(context).text('playlist_tracks_error')));
          }

          final tracks = snapshot.data ?? const <Track>[];
          final tracksByIdentity = <String, Track>{
            for (final track in tracks)
              '${track.mediaStoreVolume}:${track.mediaStoreId}': track,
          };

          if (currentPlaylist.songs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 104,
                      height: 104,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                      ),
                      child: Icon(
                        Icons.queue_music_rounded,
                        size: 48,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      V27Strings.of(context).text('playlist_waiting'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      V27Strings.of(context).text('add_tracks_prompt'),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            );
          }

          var firstAvailableIndex = -1;
          for (var i = 0; i < currentPlaylist.songs.length; i++) {
            if (tracksByIdentity[currentPlaylist.songs[i].key] != null) {
              firstAvailableIndex = i;
              break;
            }
          }

          void playFrom(int index, Track track) {
            ref.read(playbackControllerProvider.notifier).playQueue(
                  PlaylistQueueSpec(playlistId),
                  startIndex: index,
                  startVolume: track.mediaStoreVolume,
                  startMediaStoreId: track.mediaStoreId,
                );
          }

          return CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: isDark
                                ? [
                                    V27Palette.midnight,
                                    Color.lerp(Theme.of(context).colorScheme.primary, V27Palette.midnight, 0.72)!,
                                  ]
                                : [
                                    Color.lerp(Theme.of(context).colorScheme.primary, Colors.white, 0.84)!,
                                    const Color(0xFFE9EEF2),
                                  ],
                          ),
                          borderRadius: BorderRadius.circular(V27Radius.xl),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.22),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 76,
                                  height: 76,
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.16),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Icon(
                                    Icons.queue_music_rounded,
                                    size: 42,
                                    color: Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        V27Strings.of(context).text('your_playlist_header'),
                                        style: TextStyle(
                                          color: Theme.of(context).colorScheme.primary,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 1.8,
                                        ),
                                      ),
                                      const SizedBox(height: 7),
                                      Text(
                                        currentPlaylist.name,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                              fontWeight: FontWeight.w900,
                                              letterSpacing: -0.5,
                                            ),
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        '${currentPlaylist.songs.length} ${V27Strings.of(context).text(currentPlaylist.songs.length == 1 ? 'song' : 'songs')}',
                                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: firstAvailableIndex < 0
                                    ? null
                                    : () {
                                        final track = tracksByIdentity[
                                            currentPlaylist.songs[firstAvailableIndex].key]!;
                                        playFrom(firstAvailableIndex, track);
                                      },
                                icon: const Icon(Icons.play_arrow_rounded),
                                label: Text(V27Strings.of(context).text('play_all')),
                                style: FilledButton.styleFrom(
                                  backgroundColor: Theme.of(context).colorScheme.primary,
                                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(15),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 25),
                      Row(
                        children: [
                          Text(
                            V27Strings.of(context).text('tracks_header'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.8,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${currentPlaylist.songs.length} ${V27Strings.of(context).text('total_tracks')}',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 30),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final identity = currentPlaylist.songs[index];
                      final track = tracksByIdentity[identity.key];
                      final available = track != null;

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 9),
                        child: Material(
                          color: isDark ? V27Palette.darkSurface : Colors.white,
                          borderRadius: BorderRadius.circular(19),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(19),
                            onTap: track == null ? null : () => playFrom(index, track),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(19),
                                border: Border.all(
                                  color: isDark
                                      ? V27Palette.darkBorder
                                      : V27Palette.lightBorder,
                                ),
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 27,
                                    child: Text(
                                      '${index + 1}'.padLeft(2, '0'),
                                      textAlign: TextAlign.center,
                                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 9),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: SizedBox(
                                      width: 54,
                                      height: 54,
                                      child: track == null
                                          ? Container(
                                              color: isDark
                                                  ? V27Palette.darkSurfaceElevated
                                                  : V27Palette.lightBorder,
                                              child: Icon(
                                                Icons.music_off_rounded,
                                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                                              ),
                                            )
                                          : TrackArtwork(
                                              contentUri: track.contentUri,
                                              version: Object.hash(
                                                track.mediaStoreGenerationModified ??
                                                    track.dateModified,
                                                track.derivedCacheEpoch,
                                              ),
                                              size: 54,
                                              artSize: 128,
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          track?.title ?? V27Strings.of(context).text('unavailable_track'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                                fontWeight: FontWeight.w800,
                                                color: available
                                                    ? null
                                                    : Theme.of(context).colorScheme.onSurfaceVariant,
                                              ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          track == null
                                              ? V27Strings.of(context).text('no_longer_in_library')
                                              : '${track.artist} • ${track.album}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                                              ),
                                        ),
                                        if (track != null) ...[
                                          const SizedBox(height: 4),
                                          Text(
                                            _formatDuration(track.durationMs),
                                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                                  color: Theme.of(context).colorScheme.primary,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  Icon(
                                    available
                                        ? Icons.play_circle_outline_rounded
                                        : Icons.warning_amber_rounded,
                                    color: available
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(context).colorScheme.onSurfaceVariant,
                                    size: 23,
                                  ),
                                  const SizedBox(width: 2),
                                  IconButton(
                                    tooltip: V27Strings.of(context).text('remove_from_playlist'),
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(Icons.close_rounded, size: 20),
                                    onPressed: () => ref
                                        .read(playlistStoreProvider.notifier)
                                        .removeTrackAt(playlistId, index),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                    childCount: currentPlaylist.songs.length,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CustomSleepTimerDialog extends StatefulWidget {
  const _CustomSleepTimerDialog({required this.initialMinutes});

  final int initialMinutes;

  @override
  State<_CustomSleepTimerDialog> createState() =>
      _CustomSleepTimerDialogState();
}

class _CustomSleepTimerDialogState extends State<_CustomSleepTimerDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initialMinutes.toString(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _start() {
    final value = int.tryParse(_controller.text.trim());
    if (value == null || value < 1 || value > 720) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(V27Strings.of(context).text('whole_number')),
        ),
      );
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(V27Strings.of(context).text('custom_sleep_timer')),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: V27Strings.of(context).text('minutes'),
          helperText: V27Strings.of(context).text('enter_duration'),
        ),
        onSubmitted: (_) => _start(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(V27Strings.of(context).text('cancel')),
        ),
        FilledButton(
          onPressed: _start,
          child: Text(V27Strings.of(context).text('start')),
        ),
      ],
    );
  }
}
