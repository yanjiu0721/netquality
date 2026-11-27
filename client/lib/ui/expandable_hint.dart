// Copyright (C) 2026 言灸
// SPDX-License-Identifier: AGPL-3.0-only

import 'package:flutter/material.dart';

/// Helper or hint copy that stays one line until it actually overflows.
/// Text that fits is not a button. Text that would end in an ellipsis can be
/// tapped to show the rest, and tapped again to collapse.
class ExpandableHint extends StatefulWidget {
  const ExpandableHint({super.key, required this.text});

  final String text;

  @override
  State<ExpandableHint> createState() => _ExpandableHintState();
}

class _ExpandableHintState extends State<ExpandableHint> {
  var _expanded = false;

  @override
  void didUpdateWidget(ExpandableHint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = (theme.textTheme.bodySmall ?? const TextStyle(fontSize: 12))
        .copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.3);
    return LayoutBuilder(
      builder: (context, constraints) {
        final overflows = _exceedsOneLine(
          text: widget.text,
          style: style,
          maxWidth: constraints.maxWidth,
          textScaler: MediaQuery.textScalerOf(context),
          direction: Directionality.of(context),
        );
        final shown = Text(
          widget.text,
          style: style,
          maxLines: overflows && !_expanded ? 1 : null,
          overflow: overflows && !_expanded
              ? TextOverflow.ellipsis
              : TextOverflow.clip,
        );
        final padded = Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: shown,
        );
        if (!overflows) {
          return padded;
        }
        return Semantics(
          button: true,
          hint: _expanded ? '点一下收起' : '点一下展开全文',
          child: InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: padded,
          ),
        );
      },
    );
  }
}

bool _exceedsOneLine({
  required String text,
  required TextStyle style,
  required double maxWidth,
  required TextScaler textScaler,
  required TextDirection direction,
}) {
  if (!maxWidth.isFinite || maxWidth <= 0) {
    return false;
  }
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    textDirection: direction,
    textScaler: textScaler,
  )..layout(maxWidth: maxWidth);
  final exceeds = painter.didExceedMaxLines;
  painter.dispose();
  return exceeds;
}
