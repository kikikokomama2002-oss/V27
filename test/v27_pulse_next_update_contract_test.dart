import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current;
  String read(String path) => File('${root.path}/$path').readAsStringSync();

  test('8D processor is wired into Media3 PCM audio sink and settings persist', () {
    final holder = read('android/app/src/main/kotlin/com/example/musicplayer/playback/PlayerHolder.kt');
    final processor = read('android/app/src/main/kotlin/com/example/musicplayer/playback/EightDAudioProcessor.kt');
    final channel = read('android/app/src/main/kotlin/com/example/musicplayer/channels/PlayerChannel.kt');
    final dart = read('lib/playback/player_channel.dart');
    final equalizer = read('lib/features/equalizer/equalizer_screen.dart');
    expect(holder, contains('setAudioProcessors(arrayOf<AudioProcessor>(eightDAudioProcessor))'));
    expect(holder, contains('setEnableAudioTrackPlaybackParams(enableAudioOutputPlaybackParams)'));
    expect(holder, contains('import androidx.media3.common.util.UnstableApi'));
    expect(processor, contains('import androidx.media3.common.util.UnstableApi'));
    expect(holder, contains('EIGHT_D_ENABLED_KEY'));
    expect(holder, contains('putBoolean(EIGHT_D_ENABLED_KEY, enabled)'));
    expect(processor, contains('C.ENCODING_PCM_16BIT'));
    expect(processor, contains('C.ENCODING_PCM_FLOAT'));
    expect(processor, contains('sin(phase)'));
    expect(processor, contains('targetIntensity <= 0.0001f'));
    expect(processor, contains('alignedInput.limit(alignedInput.position() + frameCount * frameSize)'));
    expect(processor, contains('val leftGain = if (pan > 0.0) 1.0 - pan else 1.0'));
    expect(channel, contains('setEightDAudioEnabled'));
    expect(dart, contains('getEightDAudioSettings'));
    expect(equalizer, contains('_buildEightDAudioCard(context)'));
    expect(equalizer, contains('onChangeEnd: enabled ? _setEightDIntensity : null'));
    expect(equalizer, contains('onChangeEnd: enabled ? _setEightDSpeed : null'));
  });

  test('Dashboard sections use lazy scroll reveal transitions', () {
    final dashboard = read('lib/features/library/library_dashboard.dart');
    expect(dashboard, contains('SliverList('));
    expect(dashboard, contains('_ScrollRevealSection'));
    expect(dashboard, contains('FadeTransition('));
    expect(dashboard, contains('SlideTransition('));
    expect(dashboard, contains('AutomaticKeepAliveClientMixin'));
  });
}
