// ============================================================================
// ETAPA 13 — Desenho da planta de fundo
// ============================================================================
// O QUE É:       FloorPlanPainter (planta vetorial: piso, paredes, móveis) e NetworkFloorPlanImage
//                (imagem da rede com carregamento e queda para o desenho vetorial).
// COMO FUNCIONA: Quando uma planta não tem imagem, os cômodos (RoomDef) viram piso texturizado e
//                móveis escolhidos pelo nome do cômodo (quarto → cama, sala → sofá, jantar → mesa…).
// USADO POR:     tela_simulador e gerador_pdf (fundo do mapa do laudo).
// ONDE MEXER:    Móveis por tipo de cômodo: _drawFurniture; aparência do piso: _drawFloor.
// ============================================================================
part of '../../main.dart';

// ---------------------------------------------------------------------------
// Pintura: planta baixa ilustrada (piso texturizado + paredes espessas +
// silhuetas de móveis), usada quando não há imagem disponível.
// ---------------------------------------------------------------------------

class FloorPlanPainter extends CustomPainter {
  final List<RoomDef> rooms;
  const FloorPlanPainter(this.rooms);

  bool _isWetArea(String label) {
    final l = label.toLowerCase();
    return l.contains('banheiro') || l.contains('lavabo') || l.contains('lavanderia') || l.contains('cozinha') || l.contains('copa');
  }

  void _drawFloor(Canvas canvas, Rect r, String label) {
    if (_isWetArea(label)) {
      canvas.drawRect(r, Paint()..color = const Color(0xFFF3F4F6));
      final grout = Paint()
        ..color = const Color(0xFFDDE3EA)
        ..strokeWidth = 1;
      const tile = 16.0;
      for (double x = r.left; x < r.right; x += tile) {
        canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), grout);
      }
      for (double y = r.top; y < r.bottom; y += tile) {
        canvas.drawLine(Offset(r.left, y), Offset(r.right, y), grout);
      }
    } else {
      canvas.drawRect(r, Paint()..color = const Color(0xFFE7D2B0));
      final plank = Paint()
        ..color = const Color(0xFFD4B489)
        ..strokeWidth = 1;
      const step = 18.0;
      for (double y = r.top; y < r.bottom; y += step) {
        canvas.drawLine(Offset(r.left, y), Offset(r.right, y), plank);
      }
    }
  }

  void _drawFurniture(Canvas canvas, Rect r, String label) {
    final wood = Paint()..color = const Color(0xFFB08968);
    final woodLight = Paint()..color = const Color(0xFFC9A67D);
    final fabric = Paint()..color = const Color(0xFFAEB8C4);
    final white = Paint()..color = Colors.white;
    final metal = Paint()..color = const Color(0xFF94A3B8);
    final short = min(r.width, r.height);
    final l = label.toLowerCase();

    if (l.contains('quarto') || l.contains('suíte') || l.contains('suite')) {
      final bed = Rect.fromLTWH(r.left + r.width * 0.10, r.top + r.height * 0.10, r.width * 0.52, r.height * 0.60);
      canvas.drawRRect(RRect.fromRectAndRadius(bed, const Radius.circular(6)), woodLight);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(bed.left, bed.top, bed.width, bed.height * 0.24), const Radius.circular(6)),
        white,
      );
    } else if (l.contains('jantar')) {
      final table = Rect.fromLTWH(r.left + r.width * 0.24, r.top + r.height * 0.32, r.width * 0.52, r.height * 0.28);
      canvas.drawRRect(RRect.fromRectAndRadius(table, const Radius.circular(4)), wood);
      for (final dx in [0.30, 0.50, 0.70]) {
        canvas.drawCircle(Offset(r.left + r.width * dx, r.top + r.height * 0.18), short * 0.035, woodLight);
        canvas.drawCircle(Offset(r.left + r.width * dx, r.top + r.height * 0.68), short * 0.035, woodLight);
      }
    } else if (l.contains('sala') && !l.contains('reunião') && !l.contains('reuniao')) {
      final sofa = Rect.fromLTWH(r.left + r.width * 0.06, r.top + r.height * 0.55, r.width * 0.40, r.height * 0.30);
      canvas.drawRRect(RRect.fromRectAndRadius(sofa, const Radius.circular(8)), fabric);
      canvas.drawCircle(Offset(r.left + r.width * 0.60, r.top + r.height * 0.70), short * 0.07, woodLight);
    } else if (l.contains('cozinha') || l.contains('copa')) {
      canvas.drawRect(Rect.fromLTWH(r.left, r.top, r.width * 0.20, r.height), metal);
      canvas.drawRect(Rect.fromLTWH(r.left + r.width * 0.04, r.top + r.height * 0.10, r.width * 0.12, r.height * 0.14), white);
    } else if (l.contains('banheiro') || l.contains('lavabo')) {
      canvas.drawOval(Rect.fromLTWH(r.right - r.width * 0.32, r.bottom - r.height * 0.30, r.width * 0.24, r.height * 0.20), white);
      canvas.drawRect(Rect.fromLTWH(r.left + r.width * 0.08, r.top + r.height * 0.08, r.width * 0.22, r.height * 0.12), white);
    } else if (l.contains('reunião') ||
        l.contains('reuniao') ||
        l.contains('diretoria') ||
        l.contains('open space') ||
        l.contains('escritório') ||
        l.contains('escritorio')) {
      final table = Rect.fromLTWH(r.left + r.width * 0.18, r.top + r.height * 0.35, r.width * 0.64, r.height * 0.28);
      canvas.drawRRect(RRect.fromRectAndRadius(table, const Radius.circular(4)), wood);
    } else if (l.contains('varanda')) {
      final rail = Paint()
        ..color = const Color(0xFF94A3B8)
        ..strokeWidth = 1.4;
      for (double x = r.left + 6; x < r.right - 6; x += 10) {
        canvas.drawLine(Offset(x, r.top + 6), Offset(x, r.top + 20), rail);
      }
    } else if (l.contains('escada')) {
      final step = Paint()
        ..color = const Color(0xFF8B6A4A)
        ..strokeWidth = 2;
      const steps = 8;
      for (var i = 0; i <= steps; i++) {
        final y = r.top + r.height * i / steps;
        canvas.drawLine(Offset(r.left + r.width * 0.10, y), Offset(r.right - r.width * 0.10, y), step);
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF7F5F0));

    Rect rectOf(RoomDef room) => Rect.fromLTWH(
          room.rectFrac.left * size.width,
          room.rectFrac.top * size.height,
          room.rectFrac.width * size.width,
          room.rectFrac.height * size.height,
        );

    for (final room in rooms) {
      final rect = rectOf(room);
      _drawFloor(canvas, rect, room.label);
      _drawFurniture(canvas, rect, room.label);
    }

    // Paredes estruturais espessas por cima do piso/móveis.
    final wallPaint = Paint()
      ..color = const Color(0xFF211F1C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(4.0, size.shortestSide * 0.018)
      ..strokeJoin = StrokeJoin.round;
    for (final room in rooms) {
      final rect = rectOf(room);
      canvas.drawRect(rect, wallPaint);

      final tp = TextPainter(
        text: TextSpan(
          text: room.label,
          style: const TextStyle(
            color: Colors.black87,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            backgroundColor: Color(0xB3FFFFFF),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: rect.width - 8);
      tp.paint(canvas, Offset(rect.left + 6, rect.top + 6));
    }

    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = const Color(0xFF211F1C)
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(6.0, size.shortestSide * 0.03),
    );
  }

  @override
  bool shouldRepaint(covariant FloorPlanPainter oldDelegate) => oldDelegate.rooms != rooms;
}

// ---------------------------------------------------------------------------
// Planta de fundo com imagem remota (Image.network), com indicador de
// carregamento e um fallback (asset local ou desenho vetorial) se a rede falhar.
// ---------------------------------------------------------------------------

class NetworkFloorPlanImage extends StatelessWidget {
  final String url;
  final Widget fallback;
  const NetworkFloorPlanImage({super.key, required this.url, required this.fallback});

  @override
  Widget build(BuildContext context) {
    return Image.network(
      url,
      fit: BoxFit.fill,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Container(
          color: Colors.grey.shade100,
          alignment: Alignment.center,
          child: const CircularProgressIndicator(),
        );
      },
      errorBuilder: (context, error, stackTrace) => fallback,
    );
  }
}
