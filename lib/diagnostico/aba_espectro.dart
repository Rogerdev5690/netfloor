// ============================================================================
// ETAPA 23 — Aba Espectro de canais
// ============================================================================
// O QUE É:       Gráfico de trapézios por rede (2.4 e 5 GHz), destaque da sua rede e a lista de
//                canais recomendados.
// COMO FUNCIONA: SpectrumPainter desenha um trapézio por rede (base = largura do canal, altura =
//                sinal). A rede conectada (e a de mesmo nome em outra banda) fica em verde.
// USADO POR:     tela_diagnostico.
// ONDE MEXER:    Escala/cores do gráfico (SpectrumPainter) e o cartão "Rede conectada".
// ============================================================================
part of '../main.dart';

// ---------------------------------------------------------------------------
// Aba 1 — Espectro de canais & saúde do canal
// ---------------------------------------------------------------------------

const Color kConnectedColor = Color(0xFF00E676);
const Color kNeighborColor = Color(0xFF94A3B8);

class SpectrumTab extends StatelessWidget {
  final DiagnosticsController c;
  const SpectrumTab({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final nets = c.networks.where((n) => n.band == c.band).toList();
    final mySsid = c.connectedSsid;
    final health = computeChannelHealth(c.band, c.networks, connectedSsid: mySsid);
    final hasSibling = mySsid.isNotEmpty && nets.any((n) => !n.connected && n.ssid == mySsid);
    final best = ([...health]..sort((a, b) => a.score != b.score ? a.score.compareTo(b.score) : a.channel.compareTo(b.channel)))
        .take(3)
        .toList();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _PermissionCard(c: c),
        SegmentedButton<WifiBand>(
          segments: const [
            ButtonSegment(value: WifiBand.ghz24, label: Text('2.4 GHz'), icon: Icon(Icons.wifi)),
            ButtonSegment(value: WifiBand.ghz5, label: Text('5 GHz'), icon: Icon(Icons.wifi_channel)),
          ],
          selected: {c.band},
          onSelectionChanged: (s) => c.setBand(s.first),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            _LegendDot(
              color: kConnectedColor,
              label: hasSibling ? 'Sua rede "$mySsid" (conectada em outra banda)' : 'Rede conectada',
            ),
            const _LegendDot(color: kNeighborColor, label: 'Redes vizinhas'),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 280,
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
          decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(12)),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = c.band == WifiBand.ghz5;
              final width = wide ? max(constraints.maxWidth, 980.0) : constraints.maxWidth;
              final chart = CustomPaint(
                size: Size(width, constraints.maxHeight),
                painter: SpectrumPainter(band: c.band, networks: nets, connectedSsid: mySsid),
              );
              return wide ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: chart) : chart;
            },
          ),
        ),
        _ConnectedApCard(c: c),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                c.lastScan == null
                    ? (c.scanning ? 'Varrendo…' : 'Sem varredura ainda')
                    : 'Última varredura: ${_clock(c.lastScan!)} · ${nets.length} redes em ${c.band == WifiBand.ghz24 ? '2.4' : '5'} GHz',
                style: TextStyle(fontSize: 12, color: _muted(context)),
              ),
            ),
            if (c.scanning)
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            else
              TextButton.icon(onPressed: c.scanNow, icon: const Icon(Icons.refresh, size: 18), label: const Text('Escanear')),
          ],
        ),
        if (c.scanError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(c.scanError!, style: TextStyle(fontSize: 12, color: Colors.red.shade700)),
          ),
        if (c.isNative && c.lastScan != null && c.networks.isEmpty && c.scanError == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Nenhuma rede retornada. Confirme que a Localização (GPS) está ativada; o Android também limita a frequência das varreduras.',
              style: TextStyle(fontSize: 12, color: _muted(context)),
            ),
          ),
        _ChannelHealthCard(band: c.band, health: health, best: best),
      ],
    );
  }
}

/// Detalhes da rede conectada: SSID, BSSID, banda/canal, largura e dBm reais.
class _ConnectedApCard extends StatelessWidget {
  final DiagnosticsController c;
  const _ConnectedApCard({required this.c});

  @override
  Widget build(BuildContext context) {
    WifiNetwork? ap;
    for (final n in c.networks) {
      if (n.connected) {
        ap = n;
        break;
      }
    }
    final link = c.link;
    if (ap == null && (link == null || !link.connected)) return const SizedBox.shrink();

    final ssid = ap != null ? ap.displayName : (link!.ssid.isEmpty ? '(rede oculta)' : link.ssid);
    final rawBssid = ap?.bssid ?? link!.bssid;
    final bssid = rawBssid.isEmpty || rawBssid == '02:00:00:00:00:00' ? 'oculto pelo Android' : rawBssid;
    final bandChannel = ap != null
        ? '${ap.band == WifiBand.ghz24 ? '2.4' : '5'} GHz · canal ${ap.channel}'
        : '${link!.bandLabel} · canal ${link.channel}';
    final width = ap != null ? '${ap.widthMhz} MHz' : '--';
    final level = ap != null ? '${ap.level} dBm' : '${link!.rssi} dBm';

    Widget kv(String label, String value) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(fontSize: 11, color: _muted(context))),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        );

    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(width: 10, height: 10, decoration: const BoxDecoration(color: kConnectedColor, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                const Text('Rede conectada', style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 24,
              runSpacing: 10,
              children: [
                kv('SSID', ssid),
                kv('BSSID', bssid),
                kv('Banda · canal', bandChannel),
                kv('Largura', width),
                kv('Sinal', level),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}

class _ChannelHealthCard extends StatelessWidget {
  final WifiBand band;
  final List<ChannelHealth> health;
  final List<ChannelHealth> best;
  const _ChannelHealthCard({required this.band, required this.health, required this.best});

  @override
  Widget build(BuildContext context) {
    final head = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _muted(context));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Saúde do canal', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 2),
            Text(
              'Interferência estimada por canal de 20 MHz, contando só as redes vizinhas (a sua rede fica de fora).',
              style: TextStyle(fontSize: 12, color: _muted(context)),
            ),
            const SizedBox(height: 10),
            Text('Recomendados', style: head),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final h in best)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: CircleAvatar(backgroundColor: h.rating.color, radius: 5),
                    label: Text('Canal ${h.channel} · ${h.rating.label}', style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            const Divider(height: 20),
            Row(
              children: [
                SizedBox(width: 62, child: Text('Canal', style: head)),
                SizedBox(width: 70, child: Text('Freq.', style: head)),
                Expanded(child: Text('Interferência', style: head)),
                SizedBox(width: 44, child: Text('Redes', style: head, textAlign: TextAlign.center)),
                SizedBox(width: 84, child: Text('Saúde', style: head, textAlign: TextAlign.end)),
              ],
            ),
            const SizedBox(height: 4),
            for (final h in health)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(width: 62, child: Text('${h.channel}', style: const TextStyle(fontWeight: FontWeight.w600))),
                    SizedBox(width: 70, child: Text('${h.freq}', style: TextStyle(fontSize: 12, color: _muted(context)))),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: (h.score / 2.5).clamp(0.0, 1.0).toDouble(),
                          minHeight: 8,
                          color: h.rating.color,
                          backgroundColor: Colors.grey.shade200,
                        ),
                      ),
                    ),
                    SizedBox(width: 44, child: Text('${h.overlapping}', textAlign: TextAlign.center)),
                    SizedBox(
                      width: 84,
                      child: Text(
                        h.rating.label,
                        textAlign: TextAlign.end,
                        style: TextStyle(fontWeight: FontWeight.w600, color: h.rating.color),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Gráfico de espectro: um trapézio por rede (largura = 20/40/80/160 MHz,
/// altura = intensidade). A rede conectada — e a de mesmo nome em outra banda,
/// como o 2.4 GHz do roteador em que você está no 5 GHz — fica em cor acesa e
/// sublinhada; vizinhas em cinza.
class SpectrumPainter extends CustomPainter {
  final WifiBand band;
  final List<WifiNetwork> networks;
  final String connectedSsid;
  SpectrumPainter({required this.band, required this.networks, this.connectedSsid = ''});

  bool _isMine(WifiNetwork n) => n.connected || (connectedSsid.isNotEmpty && n.ssid == connectedSsid);

  static const double _left = 36, _right = 10, _top = 16, _bottom = 30;
  static const double _minDbm = -100, _maxDbm = -30;

  double get _xMin => band == WifiBand.ghz24 ? 2396 : 5160;
  double get _xMax => band == WifiBand.ghz24 ? 2498 : 5840;

  double _text(
    Canvas canvas,
    String text,
    Offset pos, {
    double size = 10,
    Color color = Colors.white70,
    FontWeight weight = FontWeight.normal,
    double maxWidth = double.infinity,
    bool centerX = false,
    bool anchorBottom = false,
    bool rightAlign = false,
    bool underline = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: size,
          color: color,
          fontWeight: weight,
          decoration: underline ? TextDecoration.underline : TextDecoration.none,
          decorationColor: color,
          decorationThickness: 2,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    var dx = pos.dx;
    if (centerX) dx -= tp.width / 2;
    if (rightAlign) dx -= tp.width;
    tp.paint(canvas, Offset(dx, anchorBottom ? pos.dy - tp.height : pos.dy));
    return tp.width;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final plot = Rect.fromLTRB(_left, _top, size.width - _right, size.height - _bottom);
    double xOf(double mhz) => plot.left + (mhz - _xMin) / (_xMax - _xMin) * plot.width;
    double yOf(double dbm) =>
        plot.bottom - ((dbm.clamp(_minDbm, _maxDbm) - _minDbm) / (_maxDbm - _minDbm)) * plot.height;

    final grid = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    for (var dbm = -90; dbm <= -40; dbm += 10) {
      final y = yOf(dbm.toDouble());
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _text(canvas, '$dbm', Offset(plot.left - 4, y - 6), size: 9, rightAlign: true);
    }
    canvas.drawLine(Offset(plot.left, plot.bottom), Offset(plot.right, plot.bottom), Paint()..color = Colors.white38);

    final channels = band == WifiBand.ghz24 ? [for (var c = 1; c <= 14; c++) c] : kChannels5Ghz;
    for (final ch in channels) {
      final x = xOf(channelToMhz(band, ch).toDouble());
      canvas.drawLine(Offset(x, plot.bottom), Offset(x, plot.bottom + 4), Paint()..color = Colors.white38);
      _text(canvas, '$ch', Offset(x, plot.bottom + 6), size: 9, centerX: true);
    }
    _text(canvas, 'Canal', Offset(plot.center.dx, size.height - 2), size: 9, color: Colors.white54, centerX: true, anchorBottom: true);

    canvas.save();
    canvas.clipRect(plot.inflate(2));

    Path trapezoid(WifiNetwork n) {
      final half = n.widthMhz / 2;
      final inset = n.widthMhz * 0.10;
      final yTop = yOf(n.level.toDouble());
      return Path()
        ..moveTo(xOf(n.centerFreq - half), plot.bottom)
        ..lineTo(xOf(n.centerFreq - half + inset), yTop)
        ..lineTo(xOf(n.centerFreq + half - inset), yTop)
        ..lineTo(xOf(n.centerFreq + half), plot.bottom)
        ..close();
    }

    final neighbors = networks.where((n) => !_isMine(n)).toList()..sort((a, b) => a.level.compareTo(b.level));
    final connected = networks.where(_isMine).toList();

    for (final n in neighbors) {
      final path = trapezoid(n);
      canvas.drawPath(path, Paint()..color = kNeighborColor.withOpacity(0.16));
      canvas.drawPath(
        path,
        Paint()
          ..color = kNeighborColor.withOpacity(0.75)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
    for (final n in connected) {
      final path = trapezoid(n);
      canvas.drawPath(
        path,
        Paint()
          ..color = kConnectedColor.withOpacity(0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawPath(path, Paint()..color = kConnectedColor.withOpacity(0.38));
      canvas.drawPath(
        path,
        Paint()
          ..color = kConnectedColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
      // Sublinhado: barra grossa no eixo, cobrindo a largura do canal da rede.
      canvas.drawLine(
        Offset(xOf(n.centerFreq - n.widthMhz / 2), plot.bottom - 1.5),
        Offset(xOf(n.centerFreq + n.widthMhz / 2), plot.bottom - 1.5),
        Paint()
          ..color = kConnectedColor
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round,
      );
    }

    // Rótulos: rede conectada + as 4 vizinhas mais fortes.
    final strongest = ([...neighbors]..sort((a, b) => b.level.compareTo(a.level))).take(4);
    for (final n in strongest) {
      _text(canvas, n.displayName, Offset(xOf(n.centerFreq.toDouble()), yOf(n.level.toDouble()) - 2),
          size: 9, color: Colors.white70, centerX: true, anchorBottom: true, maxWidth: 90);
    }
    for (final n in connected) {
      final sibling = !n.connected;
      _text(
        canvas,
        '${n.displayName} (${n.level} dBm)${sibling ? ' · sua rede' : ''}',
        Offset(xOf(n.centerFreq.toDouble()), yOf(n.level.toDouble()) - 2),
        size: 11,
        color: kConnectedColor,
        weight: FontWeight.bold,
        centerX: true,
        anchorBottom: true,
        maxWidth: 170,
        underline: true,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SpectrumPainter oldDelegate) => true;
}
