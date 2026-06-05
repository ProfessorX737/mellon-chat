import 'dart:async';

import 'package:flutter/material.dart';

import 'package:fluffychat/config/themes.dart';

class TypingDots extends StatefulWidget {
  const TypingDots({super.key});

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots> {
  int _tick = 0;

  late final Timer _timer;

  static const Duration animationDuration = Duration(milliseconds: 300);

  @override
  void initState() {
    _timer = Timer.periodic(animationDuration, (_) {
      if (!mounted) return;
      setState(() {
        _tick = (_tick + 1) % 4;
      });
    });
    super.initState();
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const size = 8.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 3; i++)
          AnimatedContainer(
            duration: animationDuration * 1.5,
            curve: FluffyThemes.animationCurve,
            width: size,
            height: _tick == i ? size * 2 : size,
            margin: EdgeInsets.symmetric(
              horizontal: 2,
              vertical: _tick == i ? 4 : 8,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(size * 2),
              color: theme.colorScheme.secondary,
            ),
          ),
      ],
    );
  }
}
