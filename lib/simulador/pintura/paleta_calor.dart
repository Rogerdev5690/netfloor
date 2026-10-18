// ============================================================================
// ETAPA 12 — Paleta de cores do mapa de calor
// ============================================================================
// O QUE É:       Converte dBm em cor (azul → verde → amarelo → vermelho) e em transparência.
// COMO FUNCIONA: _signalToT normaliza o sinal (−30..+26 dBm → 0..1); _jetColor dá a cor;
//                _alphaForT deixa transparente onde o sinal é fraco (a planta aparece por baixo).
// USADO POR:     mapa_calor, tela_simulador (legenda) e gerador_pdf (legenda do laudo).
// ONDE MEXER:    Cores e limites da escala: _kStopColors, _kDbmFloor, _kDbmCeil.
// ============================================================================
part of '../../main.dart';

// ---------------------------------------------------------------------------
// Paleta de calor estilo "jet", com desvanecimento (alpha) nas áreas de
// sinal fraco para deixar a planta visível por baixo do overlay.
// ---------------------------------------------------------------------------

const double _kDbmFloor = -30.0; // t = 0.0 (sem cobertura)
const double _kDbmCeil = 26.0; // t = 1.0 (perto da potência máxima do catálogo)

const List<double> _kStops = [0.0, 0.18, 0.38, 0.58, 0.74, 0.88, 1.0];
const List<Color> _kStopColors = [
  Color(0xFF1E3A8A), // azul profundo
  Color(0xFF2563EB), // azul
  Color(0xFF06B6D4), // ciano
  Color(0xFF22C55E), // verde
  Color(0xFFFACC15), // amarelo
  Color(0xFFFB923C), // laranja
  Color(0xFFEF4444), // vermelho
];

double _signalToT(double dbm) {
  return ((dbm - _kDbmFloor) / (_kDbmCeil - _kDbmFloor)).clamp(0.0, 1.0);
}

Color _jetColor(double t) {
  for (var i = 0; i < _kStops.length - 1; i++) {
    if (t <= _kStops[i + 1] || i == _kStops.length - 2) {
      final localT = ((t - _kStops[i]) / (_kStops[i + 1] - _kStops[i])).clamp(0.0, 1.0);
      return Color.lerp(_kStopColors[i], _kStopColors[i + 1], localT)!;
    }
  }
  return _kStopColors.last;
}

/// Suaviza a transição para transparente nas áreas de sinal muito fraco.
/// [maxAlpha] é a opacidade máxima do overlay (ajustável pelo usuário).
double _alphaForT(double t, double maxAlpha) {
  const lo = 0.04, hi = 0.55;
  final x = ((t - lo) / (hi - lo)).clamp(0.0, 1.0);
  final smooth = x * x * (3 - 2 * x);
  return smooth * maxAlpha;
}
