// ============================================================================
// ETAPA 11 — A física do sinal (propagação 2.5D em metros)
// ============================================================================
// O QUE É:       SignalField.at(ponto) devolve o nível de sinal (dBm) em qualquer ponto da planta;
//                computeCoverage resume a cobertura (% forte / intermediária / ruim).
// COMO FUNCIONA: Para cada roteador: Ptx + ajuste da banda − k·log10(distância 3D) − perdas das
//                paredes cruzadas (ray-casting) − 15 dB por laje. O sinal final é o maior entre os
//                roteadores. Tudo em metros reais (escala calibrada).
// USADO POR:     mapa_calor (cores), tela_simulador (previsão nos pontos), gerador_pdf (laudo).
// ONDE MEXER:    Constantes kFloorHeightM, kSlabLossDb, kStrongDbm, kWeakDbm e a fórmula em SignalField.at.
// ============================================================================
part of '../../main.dart';

// ---------------------------------------------------------------------------
// Modelo de propagação de sinal (2.5D), agora em METROS reais
//
//   Sinal(x,y) = max_i ( Ptx_i + Δref(banda) − k(banda)·log10(d3D_i)
//                        − fator(banda) · Σ perda de paredes − 15 · Δandares )
//   d3D = sqrt(dx² + dy² + (Δandares · altura do piso)²), mínimo de 1 m
//
// A escala (m por unidade de planta) vem da largura real do pavimento, que o
// usuário calibra com a régua. Os pavimentos são empilhados sobre a mesma
// pegada (mesma posição fracionária x,y em cada andar); as paredes usadas são
// as do pavimento exibido.
// ---------------------------------------------------------------------------

const double kFloorHeightM = 3.0; // altura entre pisos
const double kSlabLossDb = 15.0; // laje de concreto, por andar (não depende da banda)

/// Limiares da legenda (dBm).
const double kStrongDbm = 12.0;
const double kWeakDbm = -10.0;

/// Teste de interseção entre dois segmentos de reta (caso geral).
bool _segmentsIntersect(Offset p1, Offset p2, Offset p3, Offset p4) {
  double orient(Offset a, Offset b, Offset c) => (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);
  final o1 = orient(p1, p2, p3);
  final o2 = orient(p1, p2, p4);
  final o3 = orient(p3, p4, p1);
  final o4 = orient(p3, p4, p2);
  return ((o1 > 0) != (o2 > 0)) && ((o3 > 0) != (o4 > 0));
}

/// Uma parede já convertida para o espaço em metros do pavimento.
class _MeterWall {
  final Offset a;
  final Offset b;
  final double attenuationDb;
  const _MeterWall(this.a, this.b, this.attenuationDb);
}

/// Campo de sinal de um pavimento: dado um ponto (fração da planta), devolve o
/// nível em dBm. Compartilhado pelo mapa de calor, pelos pontos de medição e
/// pelo laudo em PDF.
class SignalField {
  final double widthM;
  final double heightM;
  final RfBandSpec _band;
  final int floorIndex;
  final List<Offset> _pos;
  final List<double> _power;
  final List<int> _gap;
  final List<_MeterWall> _walls;

  SignalField._(this.widthM, this.heightM, this._band, this.floorIndex, this._pos, this._power, this._gap, this._walls);

  factory SignalField({
    required List<RouterNode> routers,
    required List<WallSegment> walls,
    required int floorIndex,
    required double widthM,
    required double aspect,
    required RfBand band,
  }) {
    final heightM = widthM / aspect;
    Offset toM(Offset f) => Offset(f.dx * widthM, f.dy * heightM);
    return SignalField._(
      widthM,
      heightM,
      rfBandSpec(band),
      floorIndex,
      [for (final r in routers) toM(r.frac)],
      [for (final r in routers) _specFor(r.model).txPowerDbm],
      [for (final r in routers) (r.floor - floorIndex).abs()],
      [for (final w in walls) _MeterWall(toM(w.a), toM(w.b), w.attenuationDb)],
    );
  }

  bool get hasRouters => _pos.isNotEmpty;

  /// Nível previsto (dBm) no ponto [frac] do pavimento. Sem roteadores: -1000.
  double at(Offset frac) {
    final p = Offset(frac.dx * widthM, frac.dy * heightM);
    double best = -1000.0;
    for (var i = 0; i < _pos.length; i++) {
      final dxy = (p - _pos[i]).distance;
      final dz = _gap[i] * kFloorHeightM;
      final d = max(sqrt(dxy * dxy + dz * dz), 1.0);
      double walls = 0;
      for (final w in _walls) {
        if (_segmentsIntersect(p, _pos[i], w.a, w.b)) walls += w.attenuationDb;
      }
      final v = _power[i] +
          _band.refOffsetDb -
          _band.pathLossExp * (log(d) / ln10) -
          walls * _band.wallFactor -
          _gap[i] * kSlabLossDb;
      if (v > best) best = v;
    }
    return best;
  }
}

/// Classificação da legenda para um nível em dBm.
String signalClassLabel(double dbm) {
  if (dbm >= kStrongDbm) return 'Forte';
  if (dbm >= kWeakDbm) return 'Intermediário';
  return 'Ruim';
}

/// Estatística de cobertura de um pavimento (amostragem em grade).
class CoverageStats {
  final double strongPct;
  final double midPct;
  final double weakPct;
  final double bestDbm;
  final double worstDbm;
  final Offset worstFrac;
  const CoverageStats(this.strongPct, this.midPct, this.weakPct, this.bestDbm, this.worstDbm, this.worstFrac);
}

CoverageStats computeCoverage(SignalField field, {int cols = 60}) {
  final rows = max(1, (cols * field.heightM / field.widthM).round());
  var strong = 0, mid = 0, weak = 0;
  var best = -1000.0, worst = 1000.0;
  var worstFrac = const Offset(0.5, 0.5);
  for (var j = 0; j < rows; j++) {
    for (var i = 0; i < cols; i++) {
      final f = Offset((i + 0.5) / cols, (j + 0.5) / rows);
      final v = field.at(f);
      if (v >= kStrongDbm) {
        strong++;
      } else if (v >= kWeakDbm) {
        mid++;
      } else {
        weak++;
      }
      if (v > best) best = v;
      if (v < worst) {
        worst = v;
        worstFrac = f;
      }
    }
  }
  final total = (cols * rows).toDouble();
  return CoverageStats(strong / total * 100, mid / total * 100, weak / total * 100, best, worst, worstFrac);
}
