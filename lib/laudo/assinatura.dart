// ============================================================================
// ETAPA 28 — Assinatura digital do cliente
// ============================================================================
// O QUE É:       SignaturePadPage: quadro onde o cliente assina com o dedo; SignaturePainter desenha.
// COMO FUNCIONA: Os traços são capturados por ponteiros, suavizados e exportados como PNG recortado
//                (com margem) para entrar no PDF. É assinatura eletrônica simples (imagem).
// USADO POR:     tela_laudo.
// ONDE MEXER:    Espessura/cor do traço e o recorte da imagem.
// ============================================================================
part of '../main.dart';

// ---------------------------------------------------------------------------
// Assinatura digital: quadro de captura (dedo/mouse) e exportação em PNG
// ---------------------------------------------------------------------------

class SignaturePadPage extends StatefulWidget {
  final String signerName;
  const SignaturePadPage({super.key, this.signerName = ''});

  @override
  State<SignaturePadPage> createState() => _SignaturePadPageState();
}

class _SignaturePadPageState extends State<SignaturePadPage> {
  final List<List<Offset>> _strokes = [];
  Size _size = const Size(300, 200);

  Future<Uint8List?> _export() async {
    final pts = [for (final s in _strokes) ...s];
    if (pts.isEmpty) return null;
    var minX = pts.first.dx, maxX = pts.first.dx, minY = pts.first.dy, maxY = pts.first.dy;
    for (final p in pts) {
      minX = min(minX, p.dx);
      maxX = max(maxX, p.dx);
      minY = min(minY, p.dy);
      maxY = max(maxY, p.dy);
    }
    const pad = 14.0, scale = 2.5;
    final box = Rect.fromLTRB(minX - pad, minY - pad, maxX + pad, maxY + pad);
    final w = (box.width * scale).ceil().clamp(60, 4000);
    final h = (box.height * scale).ceil().clamp(40, 4000);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = Colors.white);
    canvas.scale(scale);
    canvas.translate(-box.left, -box.top);
    SignaturePainter(_strokes, Colors.black).paint(canvas, _size);
    final image = await recorder.endRecording().toImage(w, h);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data?.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Assinatura do cliente'),
        actions: [
          TextButton(
            onPressed: _strokes.isEmpty ? null : () => setState(_strokes.clear),
            child: const Text('Limpar'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.signerName.isEmpty
                    ? 'Peça ao cliente para assinar com o dedo no quadro abaixo.'
                    : '${widget.signerName}: assine com o dedo no quadro abaixo.',
              ),
              const SizedBox(height: 12),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) {
                    _size = Size(c.maxWidth, c.maxHeight);
                    return Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: _muted(context), width: 1.5),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(11),
                        child: Listener(
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: (e) => setState(() => _strokes.add([e.localPosition])),
                          onPointerMove: (e) {
                            if (_strokes.isNotEmpty) setState(() => _strokes.last.add(e.localPosition));
                          },
                          child: Stack(
                            children: [
                              Positioned(
                                left: 16,
                                right: 16,
                                bottom: 36,
                                child: Container(height: 1.5, color: Colors.black26),
                              ),
                              const Positioned(
                                left: 18,
                                bottom: 14,
                                child: Text('assine acima da linha', style: TextStyle(color: Colors.black38, fontSize: 12)),
                              ),
                              Positioned.fill(child: CustomPaint(painter: SignaturePainter(_strokes, Colors.black))),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _strokes.isEmpty
                          ? null
                          : () async {
                              final png = await _export();
                              if (context.mounted) Navigator.pop(context, png);
                            },
                      icon: const Icon(Icons.check),
                      label: const Text('Confirmar'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SignaturePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final Color color;
  const SignaturePainter(this.strokes, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final dot = Paint()..color = color;
    for (final s in strokes) {
      if (s.length == 1) {
        canvas.drawCircle(s.first, 1.6, dot);
        continue;
      }
      final path = Path()..moveTo(s.first.dx, s.first.dy);
      for (var i = 1; i < s.length - 1; i++) {
        final mid = (s[i] + s[i + 1]) / 2; // curva suave passando pelos pontos médios
        path.quadraticBezierTo(s[i].dx, s[i].dy, mid.dx, mid.dy);
      }
      path.lineTo(s.last.dx, s.last.dy);
      canvas.drawPath(path, line);
    }
  }

  @override
  bool shouldRepaint(covariant SignaturePainter old) => true;
}
