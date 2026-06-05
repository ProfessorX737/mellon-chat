import 'package:flutter/material.dart';

class AgentSubchatIcon extends StatelessWidget {
  final double? size;

  const AgentSubchatIcon({super.key, this.size});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconTheme = IconTheme.of(context);
    final iconSize = size ?? iconTheme.size ?? 24;
    final iconColor = iconTheme.color ?? theme.colorScheme.primary;
    final badgeSize = iconSize * 0.56;

    return SizedBox.square(
      dimension: iconSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Align(
            alignment: Alignment.center,
            child: Icon(
              Icons.chat_bubble_outline,
              size: iconSize * 0.92,
              color: iconColor,
            ),
          ),
          Positioned(
            right: -1,
            bottom: -1,
            child: CustomPaint(
              size: Size.square(badgeSize),
              painter: _PlusBadgePainter(
                fillColor: iconColor,
                plusColor: theme.colorScheme.surface,
                borderColor: theme.colorScheme.surface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlusBadgePainter extends CustomPainter {
  final Color fillColor;
  final Color plusColor;
  final Color borderColor;

  const _PlusBadgePainter({
    required this.fillColor,
    required this.plusColor,
    required this.borderColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.fill;
    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    final plusPaint = Paint()
      ..color = plusColor
      ..strokeCap = StrokeCap.round
      ..strokeWidth = size.shortestSide * 0.15;
    final inset = size.shortestSide * 0.28;

    canvas
      ..drawCircle(center, radius, borderPaint)
      ..drawCircle(center, radius * 0.82, fillPaint)
      ..drawLine(
        Offset(inset, center.dy),
        Offset(size.width - inset, center.dy),
        plusPaint,
      )
      ..drawLine(
        Offset(center.dx, inset),
        Offset(center.dx, size.height - inset),
        plusPaint,
      );
  }

  @override
  bool shouldRepaint(covariant _PlusBadgePainter oldDelegate) =>
      oldDelegate.fillColor != fillColor ||
      oldDelegate.plusColor != plusColor ||
      oldDelegate.borderColor != borderColor;
}
