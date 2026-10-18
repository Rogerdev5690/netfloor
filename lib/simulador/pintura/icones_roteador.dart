// ============================================================================
// ETAPA 16 — Ícones dos roteadores
// ============================================================================
// O QUE É:       RouterDevicePainter: desenha cada modelo de roteador com código (sem imagem).
// COMO FUNCIONA: Um método _paintXxx por modelo e um switch no paint(). Assim o ícone fica nítido
//                em qualquer tamanho e aparece também dentro do PDF.
// USADO POR:     tela_simulador (marcadores), gerador_pdf e o seletor de modelo.
// ONDE MEXER:    Novo modelo de roteador: crie um _paintNovo e um case no switch.
// ============================================================================
part of '../../main.dart';

// ---------------------------------------------------------------------------
// Ícones dos roteadores, um estilo por modelo de hardware do catálogo.
// ---------------------------------------------------------------------------

class RouterDevicePainter extends CustomPainter {
  final RouterModelType model;
  const RouterDevicePainter(this.model);

  void _shadow(Canvas canvas, RRect rrect) {
    canvas.drawRRect(
      rrect.shift(const Offset(0, 1.6)),
      Paint()
        ..color = Colors.black.withOpacity(0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.0),
    );
  }

  // Huawei AX3 Pro/AX3s: roteador de mesa clássico com 4 antenas externas.
  void _paintHuawei(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final bodyRect = Rect.fromLTWH(w * 0.14, h * 0.40, w * 0.72, h * 0.36);
    final bodyRRect = RRect.fromRectAndRadius(bodyRect, Radius.circular(h * 0.09));
    _shadow(canvas, bodyRRect);

    final antennaPaint = Paint()
      ..color = const Color(0xFF2A2D38)
      ..strokeWidth = w * 0.045
      ..strokeCap = StrokeCap.round;
    final xs = [
      bodyRect.left + w * 0.06,
      bodyRect.left + w * 0.22,
      bodyRect.right - w * 0.22,
      bodyRect.right - w * 0.06,
    ];
    for (final x in xs) {
      canvas.drawLine(Offset(x, bodyRect.top + h * 0.02), Offset(x, h * 0.01), antennaPaint);
    }

    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF4B5166), Color(0xFF1E212B)],
        ).createShader(bodyRect),
    );
    canvas.drawCircle(bodyRect.center, h * 0.045, Paint()..color = const Color(0xFF22C55E));
  }

  // TP-Link Deco: cilindro/torre minimalista, sem antenas visíveis.
  void _paintDeco(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final bodyRect = Rect.fromLTWH(w * 0.30, h * 0.12, w * 0.40, h * 0.74);
    final bodyRRect = RRect.fromRectAndRadius(bodyRect, Radius.circular(w * 0.20));
    _shadow(canvas, bodyRRect);

    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF7F7F9), Color(0xFFD9D9DF)],
        ).createShader(bodyRect),
    );
    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..color = Colors.black.withOpacity(0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
    canvas.drawLine(
      Offset(bodyRect.left + 2, bodyRect.center.dy),
      Offset(bodyRect.right - 2, bodyRect.center.dy),
      Paint()
        ..color = Colors.black.withOpacity(0.07)
        ..strokeWidth = 1.0,
    );
    canvas.drawCircle(Offset(bodyRect.center.dx, bodyRect.top + h * 0.10), h * 0.035, Paint()..color = const Color(0xFF22C55E));
  }

  // Ubiquiti UniFi AP: disco de teto circular com anel de iluminação central.
  void _paintUnifi(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final center = Offset(w / 2, h / 2);
    final radius = min(w, h) * 0.42;

    canvas.drawCircle(
      center.translate(0, 1.6),
      radius,
      Paint()
        ..color = Colors.black.withOpacity(0.28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(colors: const [Color(0xFFFFFFFF), Color(0xFFE1E4E8)]).createShader(
          Rect.fromCircle(center: center, radius: radius),
        ),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.black.withOpacity(0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
    canvas.drawCircle(
      center,
      radius * 0.32,
      Paint()
        ..color = const Color(0xFF38BDF8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.05,
    );
  }

  // ZTE E2320 / E2620 (ZXHN, Wi-Fi 6): ONT/roteador branco compacto de mesa,
  // com duas antenas externas inclinadas e faixa de LEDs de status.
  void _paintZte(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final bodyRect = Rect.fromLTWH(w * 0.16, h * 0.42, w * 0.68, h * 0.34);
    final bodyRRect = RRect.fromRectAndRadius(bodyRect, Radius.circular(h * 0.07));
    _shadow(canvas, bodyRRect);

    final antennaPaint = Paint()
      ..color = const Color(0xFF3A3D46)
      ..strokeWidth = w * 0.05
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(bodyRect.left + w * 0.10, bodyRect.top + h * 0.02),
      Offset(bodyRect.left - w * 0.02, h * 0.00),
      antennaPaint,
    );
    canvas.drawLine(
      Offset(bodyRect.right - w * 0.10, bodyRect.top + h * 0.02),
      Offset(bodyRect.right + w * 0.02, h * 0.00),
      antennaPaint,
    );

    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFDFDFD), Color(0xFFE4E6EA)],
        ).createShader(bodyRect),
    );
    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..color = Colors.black.withOpacity(0.10)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
    // Faixa de LEDs de status, padrão dos ONT/roteadores ZTE.
    final ledY = bodyRect.top + bodyRect.height * 0.62;
    const ledColors = [Color(0xFF22C55E), Color(0xFF38BDF8), Color(0xFF22C55E)];
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(
        Offset(bodyRect.left + bodyRect.width * (0.32 + i * 0.18), ledY),
        h * 0.018,
        Paint()..color = ledColors[i],
      );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    switch (model) {
      case RouterModelType.huaweiAx3:
        _paintHuawei(canvas, size);
        break;
      case RouterModelType.tplinkDeco:
        _paintDeco(canvas, size);
        break;
      case RouterModelType.unifiAp:
        _paintUnifi(canvas, size);
        break;
      case RouterModelType.zteE2320:
        _paintZte(canvas, size);
        break;
    }
  }

  @override
  bool shouldRepaint(covariant RouterDevicePainter oldDelegate) => oldDelegate.model != model;
}
