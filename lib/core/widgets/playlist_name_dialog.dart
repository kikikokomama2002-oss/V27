import 'package:flutter/material.dart';
import '../localization.dart';

class PlaylistNameDialog extends StatefulWidget {
  const PlaylistNameDialog({
    super.key,
    this.title = 'Create playlist',
    this.initialValue = '',
    this.submitLabel = 'Create',
  });

  final String title;
  final String initialValue;
  final String submitLabel;

  @override
  State<PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<PlaylistNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.pop(context, _controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final strings = V27Strings.of(context);
    return AlertDialog(
      title: Text(widget.title == 'Create playlist' ? strings.text('create_playlist') : widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 60,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: strings.text('playlist_name_label')),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(strings.text('cancel')),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.submitLabel == 'Create' ? strings.text('create') : widget.submitLabel == 'Save' ? strings.text('save') : widget.submitLabel),
        ),
      ],
    );
  }
}
