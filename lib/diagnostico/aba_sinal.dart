// ============================================================================
// ETAPA 24 — Aba Sinal (caminhada com o celular)
// ============================================================================
// O QUE É:       Gráfico ao vivo do RSSI para achar onde o sinal enfraquece enquanto você anda.
// COMO FUNCIONA: Usa fl_chart; mostra mínimo/média/máximo e uma etiqueta de qualidade (Excelente a
//                Muito fraco) a partir de limiares em dBm.
// USADO POR:     tela_diagnostico.
// ONDE MEXER:    Limiares de qualidade e o visual do gráfico.
// ============================================================================
part of '../main.dart';

// ---------------------------------------------------------------------------
// Aba 2 — Monitoramento contínuo de sinal (walk-through)
// ---------------------------------------------------------------------------

({String label, Color color}) signalQuality(double dbm) {
  if (dbm >= -50) return (label: 'Excelente', color: const Color(0xFF16A34A));
  if (dbm >= -60) return (label: 'Muito bom', color: const Color(0xFF65A30D));
  if (dbm >= -70) return (label: 'Bom', color: const Color(0xFFD97706));
  if (dbm >= -80) return (label: 'Fraco', color: const Color(0xFFEA580C));
  return (label: 'Muito fraco', color: const Color(0xFFDC2626));
}

class SignalTab extends StatelessWidget {
  final DiagnosticsController c;
  const SignalTab({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final s = c.rssiSamples;
    final last = s.isEmpty ? null : s.last;
    final q = last == null ? null : signalQuality(last);
    final link = c.link;
    final minV = s.isEmpty ? null : s.reduce(min);
    final maxV = s.isEmpty ? null : s.reduce(max);
    final avg = s.isEmpty ? null : s.reduce((a, b) => a + b) / s.length;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _PermissionCard(c: c),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        last == null ? '-- dBm' : '${last.round()} dBm',
                        style: TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: q?.color),
                      ),
                      Text(
                        link == null
                            ? 'Aguardando leitura…'
                            : '${link.ssid.isEmpty ? '(rede)' : link.ssid} · ${link.bandLabel} · canal ${link.channel}',
                        style: TextStyle(fontSize: 12, color: _muted(context)),
                      ),
                    ],
                  ),
                ),
                if (q != null)
                  Chip(
                    label: Text(q.label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    backgroundColor: q.color,
                    side: BorderSide.none,
                  ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
            child: SizedBox(
              height: 240,
              child: s.isEmpty
                  ? Center(child: Text('Sem amostras ainda', style: TextStyle(color: _muted(context))))
                  : LineChart(_rssiChart(s, q!.color), duration: Duration.zero),
            ),
          ),
        ),
        Row(
          children: [
            Expanded(child: _MiniStat(label: 'Mínimo', value: minV == null ? '--' : '${minV.round()} dBm')),
            const SizedBox(width: 8),
            Expanded(child: _MiniStat(label: 'Média', value: avg == null ? '--' : '${avg.round()} dBm')),
            const SizedBox(width: 8),
            Expanded(child: _MiniStat(label: 'Máximo', value: maxV == null ? '--' : '${maxV.round()} dBm')),
          ],
        ),
        if (c.signalError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(c.signalError!, style: TextStyle(fontSize: 12, color: Colors.red.shade700)),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: c.toggleWalk,
                icon: Icon(c.walkRunning ? Icons.pause : Icons.play_arrow),
                label: Text(c.walkRunning ? 'Pausar' : 'Retomar'),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(onPressed: c.resetSignal, icon: const Icon(Icons.delete_outline), label: const Text('Limpar')),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Caminhe pelo ambiente com o celular: as quedas no gráfico mostram onde o sinal enfraquece.',
          style: TextStyle(fontSize: 12, color: _muted(context)),
        ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  const _MiniStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 11, color: _muted(context))),
            const SizedBox(height: 2),
            Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

LineChartData _rssiChart(List<double> samples, Color color) {
  final spots = <FlSpot>[
    for (var i = 0; i < samples.length; i++) FlSpot((kMaxSamples - samples.length + i).toDouble(), samples[i]),
  ];
  const noTitles = AxisTitles(sideTitles: SideTitles(showTitles: false));
  return LineChartData(
    minX: 0,
    maxX: (kMaxSamples - 1).toDouble(),
    minY: -100,
    maxY: -20,
    clipData: const FlClipData.all(),
    gridData: const FlGridData(show: true, drawVerticalLine: false, horizontalInterval: 10),
    borderData: FlBorderData(show: false),
    lineTouchData: const LineTouchData(enabled: false),
    titlesData: FlTitlesData(
      topTitles: noTitles,
      rightTitles: noTitles,
      bottomTitles: noTitles,
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 38,
          interval: 20,
          getTitlesWidget: (v, meta) => Text('${v.toInt()}', style: const TextStyle(fontSize: 10)),
        ),
      ),
    ),
    extraLinesData: ExtraLinesData(
      horizontalLines: [
        HorizontalLine(y: -60, color: Colors.green.withOpacity(0.6), strokeWidth: 1, dashArray: [6, 4]),
        HorizontalLine(y: -70, color: Colors.orange.withOpacity(0.7), strokeWidth: 1, dashArray: [6, 4]),
      ],
    ),
    lineBarsData: [
      LineChartBarData(
        spots: spots,
        isCurved: true,
        curveSmoothness: 0.2,
        color: color,
        barWidth: 3,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(show: true, color: color.withOpacity(0.15)),
      ),
    ],
  );
}
