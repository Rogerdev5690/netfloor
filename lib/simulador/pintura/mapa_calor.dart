// ============================================================================
// ETAPA 14 — Pintura do mapa de calor
// ============================================================================
// O QUE É:       HeatmapPainter: percorre a planta em uma grade e pinta cada célula com a cor do
//                sinal previsto naquele ponto.
// COMO FUNCIONA: Usa o SignalField (física) + a paleta; depois um blur suaviza o quadriculado.
//                O mesmo painter é usado na tela e no PDF do laudo.
// USADO POR:     tela_simulador e gerador_pdf.
// ONDE MEXER:    Tamanho da célula (cell) e opacidade; a cor vem da paleta_calor.
// ============================================================================
part of '../../main.dart';

// ---------------------------------------------------------------------------
// Pintura: mapa de calor 2.5D com atenuação por paredes (ray-casting) e por
// lajes (roteadores de outros pavimentos).
// ---------------------------------------------------------------------------

class HeatmapPainter extends CustomPainter {
  final SignalField field;
  final double maxAlpha;
  final double cell; // lado da célula de amostragem (px do canvas onde é pintado)
  HeatmapPainter(this.field, this.maxAlpha, {this.cell = 8.0});

  // Amostragem em grade: equilíbrio entre qualidade visual e performance.
  // A grade é depois suavizada com um blur (ver ImageFiltered no build).
  final Paint _cellPaint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    if (!field.hasRouters) return;

    for (double y = 0; y < size.height; y += cell) {
      final h = min(cell, size.height - y);
      for (double x = 0; x < size.width; x += cell) {
        final w = min(cell, size.width - x);
        final best = field.at(Offset((x + w / 2) / size.width, (y + h / 2) / size.height));

        final t = _signalToT(best);
        final alpha = _alphaForT(t, maxAlpha);
        if (alpha <= 0.003) continue;

        _cellPaint.color = _jetColor(t).withOpacity(alpha);
        canvas.drawRect(Rect.fromLTWH(x, y, w, h), _cellPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant HeatmapPainter oldDelegate) {
    // Este painter só é reconstruído dentro do AnimatedBuilder ligado ao
    // NetworkModel, ou seja, toda vez que uma nova instância é criada é
    // porque algo realmente mudou (roteador adicionado/movido/removido).
    return true;
  }
}
