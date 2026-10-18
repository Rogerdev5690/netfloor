// ============================================================================
// ETAPA 15 — Camadas desenhadas por cima do mapa
// ============================================================================
// O QUE É:       ToolOverlayPainter (paredes e régua), RadarPingPainter (anéis pulsantes dos
//                roteadores) e PointMarkerPainter (bolinha + nome dos pontos de medição).
// COMO FUNCIONA: Cada uma é um CustomPainter independente; o zoom é compensado (1/zoom) para os
//                traços e marcadores terem tamanho constante na tela.
// USADO POR:     tela_simulador e gerador_pdf.
// ONDE MEXER:    Cores/espessura das paredes, da régua e dos marcadores.
// ============================================================================
part of '../../main.dart';

// ---------------------------------------------------------------------------
// Pintura: ferramentas de desenho sobre o mapa (paredes e régua de calibração)
// ---------------------------------------------------------------------------

void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint, {double dash = 6, double gap = 4}) {
  final total = (b - a).distance;
  if (total < 0.01) return;
  final dir = (b - a) / total;
  var d = 0.0;
  while (d < total) {
    final e = min(d + dash, total);
    canvas.drawLine(a + dir * d, a + dir * e, paint);
    d += dash + gap;
  }
}

class ToolOverlayPainter extends CustomPainter {
  final CanvasTool tool;
  final List<WallSegment> builtInWalls;
  final List<WallSegment> userWalls;
  final Offset? draftA; // fração
  final Offset? draftB; // fração
  final Color draftColor;
  final String? rulerLabel;
  final double zoom; // compensa o zoom do InteractiveViewer (traços de largura constante na tela)
  ToolOverlayPainter({
    required this.tool,
    required this.builtInWalls,
    required this.userWalls,
    required this.draftA,
    required this.draftB,
    required this.draftColor,
    required this.rulerLabel,
    required this.zoom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    Offset px(Offset f) => Offset(f.dx * size.width, f.dy * size.height);
    final z = zoom <= 0 ? 1.0 : zoom;

    if (tool == CanvasTool.walls) {
      final thin = Paint()
        ..color = const Color(0xFF475569).withOpacity(0.85)
        ..strokeWidth = 2.0 / z
        ..strokeCap = StrokeCap.round;
      for (final w in builtInWalls) {
        _dashedLine(canvas, px(w.a), px(w.b), thin, dash: 7 / z, gap: 5 / z);
      }
    }
    {
      // Paredes do usuário ficam sempre visíveis (finas), para o técnico ver o que o cálculo considera.
      final bold = tool == CanvasTool.walls;
      for (final w in userWalls) {
        if (bold) {
          canvas.drawLine(
            px(w.a),
            px(w.b),
            Paint()
              ..color = Colors.white
              ..strokeWidth = 7.0 / z
              ..strokeCap = StrokeCap.round,
          );
        }
        canvas.drawLine(
          px(w.a),
          px(w.b),
          Paint()
            ..color = w.color
            ..strokeWidth = (bold ? 4.0 : 2.2) / z
            ..strokeCap = StrokeCap.round,
        );
      }
    }

    if (draftA != null && draftB != null && (tool == CanvasTool.walls || tool == CanvasTool.ruler)) {
      final a = px(draftA!);
      final b = px(draftB!);
      if (tool == CanvasTool.walls) {
        canvas.drawLine(
          a,
          b,
          Paint()
            ..color = Colors.white
            ..strokeWidth = 7.0 / z
            ..strokeCap = StrokeCap.round,
        );
        canvas.drawLine(
          a,
          b,
          Paint()
            ..color = draftColor
            ..strokeWidth = 4.0 / z
            ..strokeCap = StrokeCap.round,
        );
      } else {
        const ruler = Color(0xFFFF00C8);
        canvas.drawLine(
          a,
          b,
          Paint()
            ..color = Colors.black
            ..strokeWidth = 5.0 / z
            ..strokeCap = StrokeCap.round,
        );
        canvas.drawLine(
          a,
          b,
          Paint()
            ..color = ruler
            ..strokeWidth = 2.5 / z
            ..strokeCap = StrokeCap.round,
        );
        for (final e in [a, b]) {
          canvas.drawCircle(e, 6 / z, Paint()..color = Colors.black);
          canvas.drawCircle(e, 4.5 / z, Paint()..color = ruler);
        }
        if (rulerLabel != null) {
          final tp = TextPainter(
            text: TextSpan(
              text: rulerLabel,
              style: TextStyle(
                color: Colors.white,
                fontSize: 12 / z,
                fontWeight: FontWeight.bold,
                backgroundColor: Colors.black.withOpacity(0.78),
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          final mid = (a + b) / 2;
          tp.paint(canvas, mid + Offset(-tp.width / 2, -tp.height - 8 / z));
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant ToolOverlayPainter oldDelegate) => true;
}

// ---------------------------------------------------------------------------
// Pintura: pulso de frequência saindo do roteador (efeito "radar")
// ---------------------------------------------------------------------------

class RadarPingPainter extends CustomPainter {
  final List<RouterNode> routers; // só os do pavimento exibido
  final double t; // progresso da animação, 0..1, em loop
  final double scale; // 1/zoom: mantém o tamanho do pulso constante na tela
  RadarPingPainter(this.routers, this.t, [this.scale = 1.0]);

  static const double _minRadius = 15.0;
  static const double _maxRadius = 48.0;

  void _ring(Canvas canvas, Offset center, double localT) {
    final radius = (_minRadius + (_maxRadius - _minRadius) * localT) * scale;
    final opacity = (1 - localT).clamp(0.0, 1.0) * 0.55;
    if (opacity <= 0.01) return;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white.withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * scale,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final r in routers) {
      final center = Offset(r.frac.dx * size.width, r.frac.dy * size.height);
      _ring(canvas, center, t);
      _ring(canvas, center, (t + 0.5) % 1.0);
    }
  }

  @override
  bool shouldRepaint(covariant RadarPingPainter oldDelegate) => true;
}


/// Marcador de ponto de medição: bolinha colorida pela previsão + rótulo.
class PointMarkerPainter extends CustomPainter {
  final String label;
  final Color color;
  final bool measured;
  final double zoom;
  const PointMarkerPainter({required this.label, required this.color, required this.measured, required this.zoom});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(c, r + 1.5 / zoom, Paint()..color = Colors.white);
    canvas.drawCircle(c, r, Paint()..color = color);
    if (measured) {
      canvas.drawCircle(
        c,
        r * 0.42,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.fill,
      );
    }
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.white,
          fontSize: 11 / zoom,
          fontWeight: FontWeight.w700,
          backgroundColor: Colors.black.withOpacity(0.72),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(c.dx - tp.width / 2, c.dy - r - tp.height - 3 / zoom));
  }

  @override
  bool shouldRepaint(covariant PointMarkerPainter old) => true;
}
