import 'package:flutter_test/flutter_test.dart';

import 'source_contract_helpers.dart';

void main() {
  test('restoring a saved queue does not start playback automatically', () {
    final playbackController = readProjectFile('lib/playback/playback_controller.dart');
    final dartChannel = readProjectFile('lib/playback/player_channel.dart');
    final nativeChannel = readProjectFile(
      'android/app/src/main/kotlin/com/example/musicplayer/channels/PlayerChannel.kt',
    );
    final queueController = readProjectFile(
      'android/app/src/main/kotlin/com/example/musicplayer/playback/QueueWindowController.kt',
    );

    expectContains(playbackController, 'autoPlay: false,');
    expectContains(dartChannel, 'bool autoPlay = true,');
    expectContains(dartChannel, "'autoPlay': autoPlay,");
    expectContains(nativeChannel, 'call.argument<Boolean>("autoPlay") ?: true');
    expectContains(nativeChannel, '                            autoPlay,');
    expectContains(queueController, 'autoPlay: Boolean = true');
    expectContains(queueController, 'p.playWhenReady = autoPlay');
    expectNotContains(queueController, 'p.playWhenReady = true');
  });
}
