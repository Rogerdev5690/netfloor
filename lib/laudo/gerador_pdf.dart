// ============================================================================
// ETAPA 30 — Gerador do laudo em PDF
// ============================================================================
// O QUE É:       renderFloorRaster (desenha planta + calor + roteadores + pontos em imagem) e
//                LaudoPdf.build (monta as páginas do PDF).
// COMO FUNCIONA: O mapa é desenhado fora da tela com o mesmo motor do simulador, vira JPEG e entra no
//                PDF. Páginas: capa/resumo, um mapa por pavimento e banda, tabelas previsto × medido,
//                registros de campo, observações e assinaturas. Roda no navegador (pacote pdf).
// USADO POR:     tela_laudo.
// ONDE MEXER:    Layout/textos do PDF (LaudoPdf.build) e a qualidade do mapa (renderFloorRaster).
// ============================================================================
part of '../main.dart';

// ---------------------------------------------------------------------------
// Gerador do laudo em PDF (biblioteca `pdf`, 100% Dart — roda no navegador e
// no WebView). O mapa de calor é renderizado fora da tela (PictureRecorder) com
// o mesmo motor do simulador e incorporado como imagem.
// ---------------------------------------------------------------------------

/// Mapa renderizado fora da tela, já codificado em JPEG (o PDF o incorpora sem
/// recompressão, mantendo o arquivo leve).
class FloorRaster {
  final Uint8List jpeg;
  final int width;
  final int height;
  const FloorRaster(this.jpeg, this.width, this.height);
}

Future<ui.Image?> _loadPlanImage(FloorPlanDef plan) async {
  try {
    Uint8List? bytes = plan.memoryBytes;
    if (bytes == null && plan.assetPath != null) {
      bytes = (await rootBundle.load(plan.assetPath!)).buffer.asUint8List();
    }
    if (bytes == null) return null;
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  } catch (_) {
    return null; // sem imagem (ex.: PNG ainda não enviado) -> desenho vetorial
  }
}

/// Renderiza o pavimento [floor] na banda [band]: planta + mapa de calor +
/// paredes desenhadas + roteadores (R1, R2…) + pontos de medição + barra de escala.
Future<FloorRaster> renderFloorRaster(NetworkModel m, int floor, RfBand band, {int width = 1000}) async {
  final f = m.floors[floor];
  final size = Size(width.toDouble(), width / f.plan.aspectRatio);
  final rect = Offset.zero & size;
  final k = width / 350.0; // proporção em relação ao tamanho típico do mapa na tela
  final image = await _loadPlanImage(f.plan);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(rect, Paint()..color = Colors.white);
  if (image != null) {
    paintImage(canvas: canvas, rect: rect, image: image, fit: BoxFit.fill, filterQuality: FilterQuality.high);
  } else if (f.plan.rooms.isNotEmpty) {
    FloorPlanPainter(f.plan.rooms).paint(canvas, size);
  } else {
    canvas.drawRect(rect, Paint()..color = const Color(0xFFEEEEEE));
  }

  final field = m.fieldFor(floor, band: band);
  canvas.saveLayer(rect, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 9 * k, sigmaY: 9 * k, tileMode: TileMode.decal));
  HeatmapPainter(field, max(m.heatOpacity, 0.55), cell: 6 * k).paint(canvas, size);
  canvas.restore();

  for (final w in f.userWalls) {
    canvas.drawLine(
      Offset(w.a.dx * size.width, w.a.dy * size.height),
      Offset(w.b.dx * size.width, w.b.dy * size.height),
      Paint()
        ..color = w.color
        ..strokeWidth = 2.6 * k
        ..strokeCap = StrokeCap.round,
    );
  }

  // Roteadores numerados (a numeração é a mesma da tabela do laudo).
  for (var i = 0; i < m.routers.length; i++) {
    final r = m.routers[i];
    if (r.floor != floor) continue;
    final pos = Offset(r.frac.dx * size.width, r.frac.dy * size.height);
    final radius = 18 * k;
    canvas.save();
    canvas.translate(pos.dx - radius, pos.dy - radius);
    RouterDevicePainter(r.model).paint(canvas, Size(radius * 2, radius * 2));
    canvas.restore();
    final tp = TextPainter(
      text: TextSpan(
        text: 'R${i + 1}',
        style: TextStyle(color: Colors.white, fontSize: 11 * k, fontWeight: FontWeight.w800, backgroundColor: const Color(0xCC000000)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy + radius + 2 * k));
  }

  for (final p in m.points.where((p) => p.floor == floor)) {
    final v = field.at(p.frac);
    final pos = Offset(p.frac.dx * size.width, p.frac.dy * size.height);
    final r = 9 * k;
    canvas.save();
    canvas.translate(pos.dx - r, pos.dy - r);
    PointMarkerPainter(
      label: '${p.name} · ${v.round()} dBm',
      color: _signalClassColor(v),
      measured: p.measured != null,
      zoom: 1 / k,
    ).paint(canvas, Size(r * 2, r * 2));
    canvas.restore();
  }

  // Barra de escala (usa a largura real calibrada).
  const nice = [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0];
  var len = nice.first;
  for (final n in nice) {
    if (n <= f.widthM * 0.3) len = n;
  }
  final barPx = len / f.widthM * size.width;
  final bx = 14 * k, by = size.height - 22 * k;
  canvas.drawRect(Rect.fromLTWH(bx - 4 * k, by - 16 * k, barPx + 8 * k, 30 * k), Paint()..color = const Color(0xCCFFFFFF));
  canvas.drawRect(Rect.fromLTWH(bx, by, barPx, 4 * k), Paint()..color = Colors.black);
  final st = TextPainter(
    text: TextSpan(
      text: '${len.toStringAsFixed(len % 1 == 0 ? 0 : 1)} m',
      style: TextStyle(color: Colors.black, fontSize: 10 * k, fontWeight: FontWeight.w700),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  st.paint(canvas, Offset(bx, by - st.height - 1 * k));

  final raster = await recorder.endRecording().toImage(size.width.round(), size.height.round());
  final data = await raster.toByteData(format: ui.ImageByteFormat.rawRgba);
  final rgba = data!.buffer.asUint8List();
  final encoded = im.encodeJpg(
    im.Image.fromBytes(width: raster.width, height: raster.height, bytes: rgba.buffer, numChannels: 4, order: im.ChannelOrder.rgba),
    quality: 88,
  );
  final out = FloorRaster(Uint8List.fromList(encoded), raster.width, raster.height);
  raster.dispose();
  image?.dispose();
  return out;
}

class LaudoPdf {
  static const PdfColor _primary = PdfColor.fromInt(0xFF1E3A8A);
  static const PdfColor _muted = PdfColor.fromInt(0xFF475569);
  static const PdfColor _line = PdfColor.fromInt(0xFFCBD5E1);
  static const PdfColor _headBg = PdfColor.fromInt(0xFFE2E8F0);

  static PdfColor _pdfColor(Color c) => PdfColor(c.r, c.g, c.b);

  static Future<Uint8List> build(NetworkModel m, {required List<RfBand> bands}) async {
    final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    final italic = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Italic.ttf'));
    final r = m.report;
    final date = r.date ?? DateTime.now();

    pw.MemoryImage? logo;
    if (r.logo != null) {
      try {
        logo = pw.MemoryImage(r.logo!);
      } catch (_) {}
    }
    pw.MemoryImage? signature;
    if (r.signature != null) {
      try {
        signature = pw.MemoryImage(r.signature!);
      } catch (_) {}
    }

    // Mapas de calor: um por pavimento e banda.
    final maps = <({int floor, RfBand band, pw.MemoryImage image, CoverageStats stats})>[];
    for (final b in bands) {
      for (var i = 0; i < m.floors.length; i++) {
        final raster = await renderFloorRaster(m, i, b);
        maps.add((
          floor: i,
          band: b,
          image: pw.MemoryImage(raster.jpeg),
          stats: computeCoverage(m.fieldFor(i, band: b)),
        ));
      }
    }

    final doc = pw.Document(
      title: 'Laudo de Vistoria Wi-Fi — ${r.client.isEmpty ? m.workspaceName : r.client}',
      author: r.technician.isEmpty ? (r.company.isEmpty ? kAppName : r.company) : r.technician,
      creator: '$kAppName $kAppVersion',
      subject: 'Laudo de vistoria de cobertura Wi-Fi',
    );
    final theme = pw.ThemeData.withFont(base: regular, bold: bold, italic: italic);

    pw.TextStyle st({double size = 10, bool b = false, PdfColor? color, bool i = false}) => pw.TextStyle(
          fontSize: size,
          fontWeight: b ? pw.FontWeight.bold : pw.FontWeight.normal,
          fontStyle: i ? pw.FontStyle.italic : pw.FontStyle.normal,
          color: color ?? PdfColors.black,
        );

    pw.Widget h2(String t) => pw.Padding(
          padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
          child: pw.Text(t, style: st(size: 13, b: true, color: _primary)),
        );

    pw.Widget kv(String k, String v) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 3),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(width: 92, child: pw.Text(k, style: st(size: 9.5, color: _muted))),
              pw.Expanded(child: pw.Text(v.isEmpty ? '—' : v, style: st(size: 10.5, b: true))),
            ],
          ),
        );

    pw.Widget table(List<String> headers, List<List<String>> rows, {List<double>? widths}) {
      return pw.TableHelper.fromTextArray(
        headers: headers,
        data: rows,
        headerStyle: st(size: 8.5, b: true),
        cellStyle: st(size: 8.5),
        headerDecoration: const pw.BoxDecoration(color: _headBg),
        border: const pw.TableBorder(
          horizontalInside: pw.BorderSide(color: _line, width: 0.5),
          bottom: pw.BorderSide(color: _line, width: 0.5),
          top: pw.BorderSide(color: _line, width: 0.5),
        ),
        cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        columnWidths: widths == null ? null : {for (var i = 0; i < widths.length; i++) i: pw.FlexColumnWidth(widths[i])},
        cellAlignment: pw.Alignment.centerLeft,
        headerAlignment: pw.Alignment.centerLeft,
      );
    }

    String db(double v) => v < -500 ? '—' : v.toStringAsFixed(1);
    String ms(double? v, {int d = 1}) => v == null ? '—' : v.toStringAsFixed(d);

    // Legenda detalhada de dBm: faixa contínua + classes.
    pw.Widget legend() {
      final ticks = [-30.0, -20.0, -10.0, 0.0, 10.0, 20.0, 26.0];
      const steps = 56;
      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('Legenda — nível de sinal simulado (dBm)', style: st(size: 9, b: true)),
          pw.SizedBox(height: 4),
          pw.Row(
            children: [
              for (var i = 0; i < steps; i++)
                pw.Expanded(child: pw.Container(height: 10, color: _pdfColor(_jetColor(i / (steps - 1))))),
            ],
          ),
          pw.SizedBox(height: 2),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [for (final t in ticks) pw.Text(t.toStringAsFixed(0), style: st(size: 7.5, color: _muted))],
          ),
          pw.SizedBox(height: 6),
          pw.Row(
            children: [
              for (final c in [
                (const Color(0xFFEF4444), 'Forte: ≥ ${kStrongDbm.round()} dBm'),
                (const Color(0xFFFACC15), 'Intermediário: ${kWeakDbm.round()} a ${kStrongDbm.round()} dBm'),
                (const Color(0xFF2563EB), 'Ruim: < ${kWeakDbm.round()} dBm'),
              ]) ...[
                pw.Container(width: 9, height: 9, color: _pdfColor(c.$1)),
                pw.SizedBox(width: 4),
                pw.Text(c.$2, style: st(size: 8)),
                pw.SizedBox(width: 12),
              ],
            ],
          ),
        ],
      );
    }

    String floorName(int i) => m.floors[i].label;

    final anySimulated = m.logs.any((l) => !l.native);
    final allCalibrated = m.floors.every((f) => f.calibrated);

    // Linhas da tabela de pontos: previsão (banda atual do projeto) + medição.
    String status(double predicted, Measurement? me) {
      var critical = predicted > -500 && predicted < kWeakDbm;
      var attention = predicted > -500 && predicted < kStrongDbm;
      if (me != null) {
        if (me.rssi <= -75 || me.netLossPct >= 5 || (me.gwAvgMs ?? 0) > 30) critical = true;
        if (me.rssi <= -67 || me.netLossPct > 0 || (me.gwAvgMs ?? 0) > 15) attention = true;
      }
      return critical ? 'CRÍTICO' : (attention ? 'Atenção' : 'OK');
    }

    final pointRows = <List<String>>[];
    var criticalCount = 0;
    for (final p in m.points) {
      final v = m.fieldFor(p.floor).at(p.frac);
      final me = p.measured;
      final s = status(v, me);
      if (s == 'CRÍTICO') criticalCount++;
      pointRows.add([
        p.name,
        floorName(p.floor),
        db(v),
        v < -500 ? '—' : signalClassLabel(v),
        me == null ? '—' : '${me.rssi}',
        me == null ? '—' : '${me.linkMbps}',
        me == null ? '—' : ms(me.gwAvgMs),
        me == null ? '—' : ms(me.netAvgMs, d: 0),
        me == null ? '—' : '${me.netLossPct.toStringAsFixed(0)}%',
        s,
      ]);
    }

    // ---- Página 1 (+): capa e resumo ----
    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.fromLTRB(36, 34, 36, 40), theme: theme),
        footer: (ctx) => pw.Container(
          alignment: pw.Alignment.centerRight,
          padding: const pw.EdgeInsets.only(top: 6),
          decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _line, width: 0.5))),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('Laudo de vistoria Wi-Fi · gerado pelo $kAppName $kAppVersion', style: st(size: 8, color: _muted)),
              pw.Text('Página ${ctx.pageNumber} de ${ctx.pagesCount}', style: st(size: 8, color: _muted)),
            ],
          ),
        ),
        build: (ctx) => [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              if (logo != null)
                pw.Container(
                  width: 110,
                  height: 56,
                  alignment: pw.Alignment.centerLeft,
                  child: pw.Image(logo, fit: pw.BoxFit.contain),
                ),
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text(r.company.isEmpty ? 'Vistoria técnica de rede' : r.company, style: st(size: 13, b: true)),
                    if (r.technician.isNotEmpty) pw.Text('Técnico: ${r.technician}', style: st(size: 9.5, color: _muted)),
                    pw.Text(_fmtDate(date), style: st(size: 9.5, color: _muted)),
                  ],
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 18),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: const pw.BoxDecoration(color: _primary, borderRadius: pw.BorderRadius.all(pw.Radius.circular(6))),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('LAUDO DE VISTORIA', style: st(size: 20, b: true, color: PdfColors.white)),
                pw.SizedBox(height: 2),
                pw.Text('Cobertura e desempenho Wi-Fi', style: st(size: 11, color: PdfColors.white)),
              ],
            ),
          ),
          h2('Identificação'),
          kv('Cliente', r.client),
          kv('Endereço', r.address),
          kv('Data da vistoria', _fmtDate(date)),
          kv('Responsável', r.technician),
          kv('Empresa', r.company),
          kv('Projeto', m.workspaceName),
          h2('Resumo da simulação'),
          kv('Pavimentos', '${m.floors.length} (${[for (var i = 0; i < m.floors.length; i++) floorName(i)].join(', ')})'),
          kv('Roteadores', '${m.routers.length}'),
          kv('Bandas simuladas', bands.map((b) => rfBandSpec(b).label).join(', ')),
          kv('Escala', allCalibrated ? 'Calibrada com régua em todos os pavimentos' : 'Parcialmente estimada (não calibrada em todos os pavimentos)'),
          kv('Pontos de medição', '${m.points.length}  (críticos: $criticalCount)'),
          kv('Medições de campo', '${m.logs.length}'),
          h2('Roteadores / pontos de acesso'),
          m.routers.isEmpty
              ? pw.Text('Nenhum roteador posicionado.', style: st())
              : table(
                  ['#', 'Modelo', 'Pavimento', 'Potência (dBm)', 'Posição na planta (m)'],
                  [
                    for (var i = 0; i < m.routers.length; i++)
                      [
                        'R${i + 1}',
                        _specFor(m.routers[i].model).name,
                        floorName(m.routers[i].floor),
                        _specFor(m.routers[i].model).txPowerDbm.toStringAsFixed(0),
                        () {
                          final f = m.floors[m.routers[i].floor];
                          return 'x ${(m.routers[i].frac.dx * f.widthM).toStringAsFixed(1)} · y ${(m.routers[i].frac.dy * f.heightM).toStringAsFixed(1)}';
                        }(),
                      ],
                  ],
                  widths: [0.6, 3.2, 1.6, 1.4, 2.2],
                ),
        ],
      ),
    );

    // ---- Mapas de calor (uma página por pavimento e banda) ----
    for (final mp in maps) {
      final spec = rfBandSpec(mp.band);
      final f = m.floors[mp.floor];
      doc.addPage(
        pw.Page(
          pageTheme: pw.PageTheme(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.fromLTRB(36, 34, 36, 40), theme: theme),
          build: (ctx) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Mapa de calor — ${floorName(mp.floor)} · ${spec.label}', style: st(size: 15, b: true, color: _primary)),
              pw.SizedBox(height: 2),
              pw.Text(
                'Planta: ${f.plan.name} · largura ${f.widthM.toStringAsFixed(1)} m${f.calibrated ? ' (calibrada)' : ' (estimada)'}'
                '${mp.band == RfBand.ghz24 ? '' : ' · 5/6 GHz: paredes ×${spec.wallFactor.toStringAsFixed(2)} e alcance menor'}',
                style: st(size: 9, color: _muted),
              ),
              pw.SizedBox(height: 8),
              pw.Expanded(
                child: pw.Container(
                  decoration: pw.BoxDecoration(border: pw.Border.all(color: _line, width: 0.8)),
                  child: pw.Center(child: pw.Image(mp.image, fit: pw.BoxFit.contain)),
                ),
              ),
              pw.SizedBox(height: 8),
              legend(),
              pw.SizedBox(height: 6),
              pw.Text(
                'Cobertura do pavimento: Forte ${mp.stats.strongPct.toStringAsFixed(0)}% · '
                'Intermediária ${mp.stats.midPct.toStringAsFixed(0)}% · Ruim ${mp.stats.weakPct.toStringAsFixed(0)}% · '
                'pior ponto ${mp.stats.worstDbm.toStringAsFixed(1)} dBm '
                '(x ${(mp.stats.worstFrac.dx * f.widthM).toStringAsFixed(1)} m, y ${(mp.stats.worstFrac.dy * f.heightM).toStringAsFixed(1)} m).',
                style: st(size: 9, b: true),
              ),
            ],
          ),
        ),
      );
    }

    // ---- Diagnóstico: pontos críticos, cobertura e medições ----
    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.fromLTRB(36, 34, 36, 40), theme: theme),
        footer: (ctx) => pw.Container(
          alignment: pw.Alignment.centerRight,
          padding: const pw.EdgeInsets.only(top: 6),
          decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _line, width: 0.5))),
          child: pw.Text('Laudo de vistoria Wi-Fi · $kAppName $kAppVersion', style: st(size: 8, color: _muted)),
        ),
        build: (ctx) => [
          pw.Text('Diagnóstico e pontos críticos', style: st(size: 15, b: true, color: _primary)),
          h2('Cobertura por pavimento e banda (simulada)'),
          table(
            ['Pavimento', 'Banda', 'Forte', 'Interm.', 'Ruim', 'Pior ponto (dBm)'],
            [
              for (final mp in maps)
                [
                  floorName(mp.floor),
                  rfBandSpec(mp.band).label,
                  '${mp.stats.strongPct.toStringAsFixed(0)}%',
                  '${mp.stats.midPct.toStringAsFixed(0)}%',
                  '${mp.stats.weakPct.toStringAsFixed(0)}%',
                  '${mp.stats.worstDbm.toStringAsFixed(1)} @ (${(mp.stats.worstFrac.dx * m.floors[mp.floor].widthM).toStringAsFixed(1)} m, '
                      '${(mp.stats.worstFrac.dy * m.floors[mp.floor].heightM).toStringAsFixed(1)} m)',
                ],
            ],
            widths: [1.6, 1.0, 0.9, 0.9, 0.9, 3.0],
          ),
          h2('Pontos de medição — previsto × medido'),
          pointRows.isEmpty
              ? pw.Text('Nenhum ponto de medição foi marcado neste projeto.', style: st())
              : table(
                  ['Ponto', 'Pav.', 'Simul. (dBm)', 'Classe', 'RSSI (dBm)', 'PHY (Mbps)', 'Ping GW (ms)', 'Ping Net (ms)', 'Perda', 'Status'],
                  pointRows,
                  widths: [1.5, 1.2, 1.1, 1.3, 1.0, 1.0, 1.1, 1.1, 0.9, 1.1],
                ),
          pw.SizedBox(height: 6),
          pw.Text(
            'Nota: "Simul. (dBm)" é o nível estimado pelo simulador na banda do projeto (${rfBandSpec(m.band).label}), em escala relativa '
            '(potência de transmissão menos perdas). "RSSI" é o nível efetivamente recebido pelo aparelho de medição. '
            'Os dois valores não devem ser comparados numericamente. Status: CRÍTICO = classe Ruim, RSSI ≤ −75 dBm, perda ≥ 5% ou ping ao gateway > 30 ms; '
            'Atenção = classe Intermediária, RSSI ≤ −67 dBm, alguma perda ou ping ao gateway > 15 ms.',
            style: st(size: 8, i: true, color: _muted),
          ),
          if (anySimulated)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 6),
              child: pw.Text(
                'ATENÇÃO: há medições marcadas como simuladas (coletadas fora do aplicativo Android WaveLens Shell). '
                'Elas não representam a rede real do cliente.',
                style: st(size: 8.5, b: true, color: const PdfColor.fromInt(0xFFB91C1C)),
              ),
            ),
          if (m.logs.isNotEmpty) ...[
            h2('Registro de diagnósticos de campo (${m.logs.length})'),
            table(
              ['Data/hora', 'Ponto', 'Origem', 'Rede', 'Banda/canal', 'RSSI', 'PHY', 'GW ms', 'Net ms', 'Perda'],
              [
                for (final l in m.logs)
                  [
                    _fmtDateTime(l.time),
                    l.pointName ?? '—',
                    l.native ? 'real' : 'simulado',
                    l.ssid.isEmpty ? '—' : l.ssid,
                    '${l.bandLabel} · c${l.channel}',
                    '${l.rssi}',
                    '${l.linkMbps}',
                    ms(l.gwAvgMs),
                    ms(l.netAvgMs, d: 0),
                    '${l.netLossPct.toStringAsFixed(0)}%',
                  ],
              ],
              widths: [1.7, 1.2, 0.9, 1.5, 1.4, 0.8, 0.8, 0.8, 0.8, 0.8],
            ),
          ],
          h2('Observações do técnico'),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: _line, width: 0.8)),
            child: pw.Text(r.notes.trim().isEmpty ? 'Sem observações.' : r.notes.trim(), style: st(size: 10)),
          ),
          pw.SizedBox(height: 26),
          pw.Wrap(
            children: [
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.SizedBox(height: 62),
                        pw.Container(height: 0.8, color: PdfColors.black),
                        pw.SizedBox(height: 3),
                        pw.Text(r.technician.isEmpty ? 'Técnico responsável' : r.technician, style: st(size: 9.5, b: true)),
                        pw.Text(
                          r.technician.isEmpty ? 'Assinatura do técnico' : (r.company.isEmpty ? 'Técnico responsável' : r.company),
                          style: st(size: 8.5, color: _muted),
                        ),
                      ],
                    ),
                  ),
                  pw.SizedBox(width: 30),
                  pw.Expanded(
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Container(
                          height: 62,
                          alignment: pw.Alignment.bottomLeft,
                          child: signature == null ? pw.SizedBox() : pw.Image(signature, fit: pw.BoxFit.contain),
                        ),
                        pw.Container(height: 0.8, color: PdfColors.black),
                        pw.SizedBox(height: 3),
                        pw.Text(
                          r.signerName.trim().isEmpty ? (r.client.isEmpty ? 'Cliente' : r.client) : r.signerName.trim(),
                          style: st(size: 9.5, b: true),
                        ),
                        pw.Text(
                          r.signedAt == null ? 'Assinatura do cliente' : 'Assinado digitalmente em ${_fmtDateTime(r.signedAt!)}',
                          style: st(size: 8.5, color: _muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );

    return doc.save();
  }
}
