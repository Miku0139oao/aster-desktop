import 'package:flutter/material.dart';

/// Original Aster monogram: an A crossed by an orbital link. The same geometry
/// is used by scripts/generate-icons.py for the native and installer assets.
class AsterMark extends StatelessWidget {
  const AsterMark({super.key, this.size = 42});
  final double size;
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Aster',
    image: true,
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _AsterPainter()),
    ),
  );
}

class _AsterPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 256, size.height / 256);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, 256, 256),
        const Radius.circular(64),
      ),
      Paint()..color = const Color(0xff7652bf),
    );
    final pen = Paint()
      ..color = const Color(0xfff5efff)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 19
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      Path()
        ..moveTo(63, 196)
        ..lineTo(126, 62)
        ..lineTo(191, 196),
      pen,
    );
    canvas.drawLine(const Offset(88, 146), const Offset(166, 146), pen);
    final orbit = Paint()
      ..color = const Color(0xffd7baff)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(
      Path()
        ..moveTo(46, 164)
        ..cubicTo(90, 214, 200, 166, 211, 92),
      orbit,
    );
    canvas.drawCircle(
      const Offset(211, 92),
      12,
      Paint()..color = const Color(0xfff5efff),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
