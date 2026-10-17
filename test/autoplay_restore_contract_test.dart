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
    final setContext = extractBlock(queueController, 'fun setContext(');
    expectNotContains(setContext, 'p.playWhenReady = true');
  });

  test('Repeat All restarts the windowed queue after the final track ends', () {
    final queueController = readProjectFile(
      'android/app/src/main/kotlin/com/example/musicplayer/playback/QueueWindowController.kt',
    );

    final restart = extractBlock(
      queueController,
      'private suspend fun restartFromBeginningIfEnded()',
    );

    expectContains(
      queueController,
      'override fun onPlaybackStateChanged(playbackState: Int)',
    );
    expectContains(
      queueController,
      'scope.launch { restartFromBeginningIfEnded() }',
    );
    expectContains(restart, 'p.playbackState != Player.STATE_ENDED');
    expectContains(restart, 'currentGlobal + 1 < totalCount');
    expectContains(restart, 'provider, cid, 0, minOf(FETCH_CHUNK, totalCount)');
    expectContains(restart, 'p.setMediaItems(');
    expectContains(restart, 'p.playWhenReady = true');
  });
}
