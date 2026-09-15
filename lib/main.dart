import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

void main() => runApp(const NetFloorApp());

class NetFloorApp extends StatelessWidget {
  const NetFloorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NetFloor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const NetFloorHomePage(),
    );
  }
}

// ---------------------------------------------------------------------------
// Planta baixa (imagem real, usada como fundo do canvas)
// ---------------------------------------------------------------------------

const String kFloorPlanAsset = 'assets/planta_casa.webp';
const double kFloorPlanAspectRatio = 1200 / 800;

// ---------------------------------------------------------------------------
// Modelo de dados
// ---------------------------------------------------------------------------

class RouterNode {
  final String id;
  Offset position;
  RouterNode({required this.id, required this.position});
}

/// Estado da rede Mesh. Usa ChangeNotifier para permitir que apenas o
/// CustomPainter do mapa de calor seja re-renderizado durante o arraste,
/// sem reconstruir toda a árvore de widgets.
class NetworkModel extends ChangeNotifier {
  final List<RouterNode> routers = [];
  int _counter = 0;

  void addRouter(Offset position) {
    routers.add(RouterNode(id: 'r${_counter++}', position: position));
    notifyListeners();
  }

  void moveRouter(String id, Offset position) {
    final router = routers.firstWhere((r) => r.id == id);
    router.position = position;
    notifyListeners();
  }

  void clear() {
    if (routers.isEmpty) return;
    routers.clear();
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// Modelo de propagação de sinal (Log-distance path loss)
// ---------------------------------------------------------------------------

const double kPixelsPerMeter = 45.0; // escala visual da planta
const double kTxPowerAt1m = -30.0; // dBm de referência a 1 metro
const double kPathLossExponent = 3.0; // ambiente interno, com paredes

/// Calcula o sinal (dBm) de UM roteador em um ponto, pelo modelo de perda
/// de percurso logarítmica: PL(d) = PL(d0) + 10*n*log10(d/d0).
double _singleRouterSignal(Offset point, Offset routerPos) {
  final distancePx = (point - routerPos).distance;
  final distanceM = max(distancePx / kPixelsPerMeter, 1.0);
  return kTxPowerAt1m - 10 * kPathLossExponent * (log(distanceM) / ln10);
}

/// Sinal combinado da rede Mesh em um ponto: o MÁXIMO entre todos os
/// roteadores ativos (união da cobertura).
double _meshSignalAt(Offset point, List<RouterNode> routers) {
  double best = -200.0;
  for (final r in routers) {
    final v = _singleRouterSignal(point, r.position);
    if (v > best) best = v;
  }
  return best;
}

// ---------------------------------------------------------------------------
// Paleta de calor estilo "jet" (vermelho -> laranja -> amarelo -> verde ->
// ciano -> azul), com desvanecimento (alpha) nas áreas de sinal fraco para
// deixar a planta visível por baixo, como em ferramentas profissionais de
// mapa de calor Wi-Fi.
// ---------------------------------------------------------------------------

const double _kDbmFloor = -90.0; // t = 0.0 (sem cobertura)
const double _kDbmCeil = -35.0; // t = 1.0 (sinal máximo)

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

/// Suaviza a transição para transparente nas áreas de sinal muito fraco,
/// formando o "halo" gradual visto em mapas de calor reais.
double _alphaForT(double t) {
  const lo = 0.04, hi = 0.55, maxAlpha = 0.82;
  final x = ((t - lo) / (hi - lo)).clamp(0.0, 1.0);
  final smooth = x * x * (3 - 2 * x);
  return smooth * maxAlpha;
}

// ---------------------------------------------------------------------------
// Pintura: mapa de calor
// ---------------------------------------------------------------------------

class HeatmapPainter extends CustomPainter {
  final List<RouterNode> routers;
  HeatmapPainter(this.routers);

  // Amostragem em grade: equilíbrio entre qualidade visual e performance.
  // A grade é depois suavizada com um blur (ver ImageFiltered no build),
  // o que permite manter um step maior sem perder o efeito de gradiente.
  static const double _cell = 8.0;

  final Paint _cellPaint = Paint();

  @override
  void paint(Canvas canvas, Size size) {
    if (routers.isEmpty) return;

    for (double y = 0; y < size.height; y += _cell) {
      final h = min(_cell, size.height - y);
      for (double x = 0; x < size.width; x += _cell) {
        final w = min(_cell, size.width - x);
        final center = Offset(x + w / 2, y + h / 2);
        final dbm = _meshSignalAt(center, routers);
        final t = _signalToT(dbm);
        final alpha = _alphaForT(t);
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
    // Comparar posições aqui é enganoso: como RouterNode.position é
    // mutável, o delegate antigo e o novo podem apontar para o MESMO
    // objeto já atualizado, fazendo a comparação sempre "dar igual" e o
    // calor ficar parado enquanto o roteador já se moveu na tela.
    return true;
  }
}

// ---------------------------------------------------------------------------
// Pintura: pulso de frequência saindo do roteador (efeito "radar")
// ---------------------------------------------------------------------------

class RadarPingPainter extends CustomPainter {
  final List<RouterNode> routers;
  final double t; // progresso da animação, 0..1, em loop
  RadarPingPainter(this.routers, this.t);

  static const double _minRadius = 15.0;
  static const double _maxRadius = 48.0;

  void _ring(Canvas canvas, Offset center, double localT) {
    final radius = _minRadius + (_maxRadius - _minRadius) * localT;
    final opacity = (1 - localT).clamp(0.0, 1.0) * 0.55;
    if (opacity <= 0.01) return;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white.withOpacity(opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final r in routers) {
      _ring(canvas, r.position, t);
      _ring(canvas, r.position, (t + 0.5) % 1.0);
    }
  }

  @override
  bool shouldRepaint(covariant RadarPingPainter oldDelegate) => true;
}

// ---------------------------------------------------------------------------
// Ícone do roteador (visual inspirado em um AP de mesa, ex.: Huawei AX3s)
// ---------------------------------------------------------------------------

class RouterDevicePainter extends CustomPainter {
  const RouterDevicePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final bodyRect = Rect.fromLTWH(w * 0.12, h * 0.38, w * 0.76, h * 0.40);
    final bodyRRect = RRect.fromRectAndRadius(bodyRect, Radius.circular(h * 0.10));

    // sombra suave
    canvas.drawRRect(
      bodyRRect.shift(const Offset(0, 1.6)),
      Paint()
        ..color = Colors.black.withOpacity(0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.0),
    );

    // antenas (formato característico de APs de mesa, ex. AX3s)
    final antennaPaint = Paint()
      ..color = const Color(0xFF2A2D38)
      ..strokeWidth = w * 0.07
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(bodyRect.left + w * 0.08, bodyRect.top + h * 0.02),
      Offset(bodyRect.left - w * 0.04, h * 0.01),
      antennaPaint,
    );
    canvas.drawLine(
      Offset(bodyRect.right - w * 0.08, bodyRect.top + h * 0.02),
      Offset(bodyRect.right + w * 0.04, h * 0.01),
      antennaPaint,
    );

    // corpo do roteador
    final bodyPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF4B5166), Color(0xFF1E212B)],
      ).createShader(bodyRect);
    canvas.drawRRect(bodyRRect, bodyPaint);
    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..color = Colors.white.withOpacity(0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );

    // LED de status
    canvas.drawCircle(bodyRect.center, h * 0.045, Paint()..color = const Color(0xFF22C55E));
  }

  @override
  bool shouldRepaint(covariant RouterDevicePainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// Tela principal
// ---------------------------------------------------------------------------

class NetFloorHomePage extends StatefulWidget {
  const NetFloorHomePage({super.key});

  @override
  State<NetFloorHomePage> createState() => _NetFloorHomePageState();
}

class _NetFloorHomePageState extends State<NetFloorHomePage> with SingleTickerProviderStateMixin {
  final NetworkModel _model = NetworkModel();
  late final AnimationController _pingController;
  static const double _markerRadius = 20.0;
  Size _lastCanvasSize = const Size(320, 320 / kFloorPlanAspectRatio);

  @override
  void initState() {
    super.initState();
    _pingController = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400))..repeat();
  }

  @override
  void dispose() {
    _pingController.dispose();
    super.dispose();
  }

  Offset _clampToBounds(Offset pos, Size bounds) {
    if (bounds.width <= 0 || bounds.height <= 0) return pos;
    return Offset(
      pos.dx.clamp(_markerRadius, max(_markerRadius, bounds.width - _markerRadius)).toDouble(),
      pos.dy.clamp(_markerRadius, max(_markerRadius, bounds.height - _markerRadius)).toDouble(),
    );
  }

  void _handleAddViaButton() {
    final size = _lastCanvasSize;
    final offset = Offset(24.0 * (_model.routers.length % 5), 24.0 * (_model.routers.length % 3));
    final pos = _clampToBounds(
      Offset(size.width / 2, size.height / 2) + offset,
      size,
    );
    _model.addRouter(pos);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_tethering),
            SizedBox(width: 8),
            Text('NetFloor'),
          ],
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildLegend(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: kFloorPlanAspectRatio,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        _lastCanvasSize = Size(constraints.maxWidth, constraints.maxHeight);
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            color: Colors.grey.shade100,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapUp: (details) {
                                final pos = _clampToBounds(details.localPosition, _lastCanvasSize);
                                _model.addRouter(pos);
                              },
                              child: AnimatedBuilder(
                                animation: _model,
                                builder: (context, _) {
                                  return Stack(
                                    children: [
                                      const Positioned.fill(
                                        child: RepaintBoundary(
                                          child: Image(
                                            image: AssetImage(kFloorPlanAsset),
                                            fit: BoxFit.fill,
                                          ),
                                        ),
                                      ),
                                      Positioned.fill(
                                        child: ImageFiltered(
                                          imageFilter: ui.ImageFilter.blur(
                                            sigmaX: 9,
                                            sigmaY: 9,
                                            tileMode: TileMode.decal,
                                          ),
                                          child: CustomPaint(
                                            painter: HeatmapPainter(List.of(_model.routers)),
                                          ),
                                        ),
                                      ),
                                      Positioned.fill(
                                        child: AnimatedBuilder(
                                          animation: _pingController,
                                          builder: (context, _) {
                                            return CustomPaint(
                                              painter: RadarPingPainter(_model.routers, _pingController.value),
                                            );
                                          },
                                        ),
                                      ),
                                      for (final r in _model.routers)
                                        _buildRouterMarker(r, _lastCanvasSize),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            _buildActionBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildRouterMarker(RouterNode router, Size bounds) {
    return Positioned(
      left: router.position.dx - _markerRadius,
      top: router.position.dy - _markerRadius,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {}, // absorve o toque para não "vazar" para o fundo e criar um roteador duplicado
        onPanUpdate: (details) {
          final newPos = _clampToBounds(router.position + details.delta, bounds);
          _model.moveRouter(router.id, newPos);
        },
        child: SizedBox(
          width: _markerRadius * 2,
          height: _markerRadius * 2,
          child: const CustomPaint(painter: RouterDevicePainter()),
        ),
      ),
    );
  }

  Widget _buildLegend() {
    Widget dot(Color c) => Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        );
    Widget item(Color c, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [dot(c), const SizedBox(width: 6), Text(label, style: const TextStyle(fontSize: 12))],
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          item(_jetColor(1.0), 'Forte (≥ -50 dBm)'),
          item(_jetColor(0.55), 'Intermediário (-51 a -70 dBm)'),
          item(_jetColor(0.15), 'Ruim (< -70 dBm)'),
        ],
      ),
    );
  }

  Widget _buildActionBar() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _handleAddViaButton,
              icon: const Icon(Icons.add),
              label: const Text('Adicionar Roteador'),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: () => setState(() => _model.clear()),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Limpar'),
          ),
        ],
      ),
    );
  }
}
