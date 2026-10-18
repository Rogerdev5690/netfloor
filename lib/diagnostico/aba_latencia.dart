// ============================================================================
// ETAPA 25 — Aba Latência e rede (ping duplo)
// ============================================================================
// O QUE É:       Compara o ping até o roteador (rede local) com o ping até a Internet (8.8.8.8).
// COMO FUNCIONA: Se só a Internet piora, o problema está fora de casa; se os dois pioram, é o Wi-Fi.
//                Mostra média, pico e perda de pacotes de cada um.
// USADO POR:     tela_diagnostico.
// ONDE MEXER:    Alvo do ping (kDnsHost), textos e cartões de estatística.
// ============================================================================
part of '../main.dart';

// ---------------------------------------------------------------------------
// Aba 3 — Latência & rede (double-ping: gateway vs DNS da Internet)
// ---------------------------------------------------------------------------

class LatencyTab extends StatelessWidget {
  final DiagnosticsController c;
  const LatencyTab({super.key, required this.c});

  static const Color _gwColor = Color(0xFF0D9488);
  static const Color _dnsColor = Color(0xFFEA580C);

  double? _last(List<double?> s) {
    for (var i = s.length - 1; i >= 0; i--) {
      if (s[i] != null) return s[i];
    }
    return null;
  }

  double? _avg(List<double?> s) {
    final v = s.whereType<double>().toList();
    return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
  }

  String _ms(double? v) => v == null ? '--' : '${v.toStringAsFixed(v < 10 ? 1 : 0)} ms';
  String _loss(int lost, int sent) => sent == 0 ? '--' : '${(lost * 100 / sent).toStringAsFixed(lost == 0 ? 0 : 1)}%';

  @override
  Widget build(BuildContext context) {
    final gwLast = _last(c.gwSamples);
    final dnsLast = _last(c.dnsSamples);
    final phy = c.link?.linkSpeedMbps;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final w = (constraints.maxWidth - 8) / 2;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatTile(
                  width: w,
                  icon: Icons.report_gmailerrorred_outlined,
                  title: 'Perda de pacotes',
                  value: 'DNS ${_loss(c.dnsLost, c.dnsSent)}',
                  subtitle: c.gatewayIp.isEmpty ? 'Gateway indisponível' : 'Gateway ${_loss(c.gwLost, c.gwSent)}',
                  color: LatencyTab._dnsColor,
                ),
                _StatTile(
                  width: w,
                  icon: Icons.dns_outlined,
                  title: 'Latência DNS ($kDnsHost)',
                  value: _ms(dnsLast),
                  subtitle: 'Média ${_ms(_avg(c.dnsSamples))}',
                  color: LatencyTab._dnsColor,
                ),
                _StatTile(
                  width: w,
                  icon: Icons.router_outlined,
                  title: 'Latência Gateway',
                  value: _ms(gwLast),
                  subtitle: c.gatewayIp.isEmpty ? 'IP não detectado' : '${c.gatewayIp} · média ${_ms(_avg(c.gwSamples))}',
                  color: LatencyTab._gwColor,
                ),
                _StatTile(
                  width: w,
                  icon: Icons.speed,
                  title: 'Velocidade PHY',
                  value: phy == null || phy == 0 ? '-- Mbps' : '$phy Mbps',
                  subtitle: 'Taxa negociada com o roteador',
                  color: Colors.indigo,
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 16, 8),
            child: Column(
              children: [
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _LegendDot(color: _gwColor, label: 'Gateway (roteador)'),
                    SizedBox(width: 16),
                    _LegendDot(color: _dnsColor, label: 'DNS Internet'),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 220,
                  child: c.gwSamples.isEmpty && c.dnsSamples.isEmpty
                      ? Center(child: Text('Sem amostras ainda', style: TextStyle(color: _muted(context))))
                      : LineChart(_latencyChart(c.gwSamples, c.dnsSamples), duration: Duration.zero),
                ),
              ],
            ),
          ),
        ),
        if (c.pingError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(c.pingError!, style: TextStyle(fontSize: 12, color: Colors.red.shade700)),
          ),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: c.togglePing,
                icon: Icon(c.pingRunning ? Icons.pause : Icons.play_arrow),
                label: Text(c.pingRunning ? 'Pausar' : 'Retomar'),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(onPressed: c.resetPing, icon: const Icon(Icons.delete_outline), label: const Text('Zerar')),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Compara a latência até o roteador (rede local) com a do DNS público: se só o DNS piora, o problema está fora de casa.',
          style: TextStyle(fontSize: 12, color: _muted(context)),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final double width;
  final IconData icon;
  final String title;
  final String value;
  final String subtitle;
  final Color color;
  const _StatTile({
    required this.width,
    required this.icon,
    required this.title,
    required this.value,
    required this.subtitle,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(title, style: TextStyle(fontSize: 11, color: _muted(context)), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 11, color: _muted(context)), maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }
}

LineChartData _latencyChart(List<double?> gw, List<double?> dns) {
  List<FlSpot> spots(List<double?> s) => [
        for (var i = 0; i < s.length; i++)
          s[i] == null ? FlSpot.nullSpot : FlSpot((kMaxSamples - s.length + i).toDouble(), s[i]!),
      ];
  final values = [...gw, ...dns].whereType<double>();
  final peak = values.isEmpty ? 40.0 : values.reduce(max);
  final maxY = max(40.0, (peak * 1.25 / 10).ceil() * 10.0);
  const noTitles = AxisTitles(sideTitles: SideTitles(showTitles: false));

  LineChartBarData bar(List<double?> s, Color color) => LineChartBarData(
        spots: spots(s),
        isCurved: false,
        color: color,
        barWidth: 2.5,
        dotData: const FlDotData(show: false),
      );

  return LineChartData(
    minX: 0,
    maxX: (kMaxSamples - 1).toDouble(),
    minY: 0,
    maxY: maxY,
    clipData: const FlClipData.all(),
    gridData: const FlGridData(show: true, drawVerticalLine: false),
    borderData: FlBorderData(show: false),
    lineTouchData: const LineTouchData(enabled: false),
    titlesData: FlTitlesData(
      topTitles: noTitles,
      rightTitles: noTitles,
      bottomTitles: noTitles,
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 34,
          getTitlesWidget: (v, meta) => Text('${v.toInt()}', style: const TextStyle(fontSize: 10)),
        ),
      ),
    ),
    lineBarsData: [
      if (gw.isNotEmpty) bar(gw, LatencyTab._gwColor),
      if (dns.isNotEmpty) bar(dns, LatencyTab._dnsColor),
    ],
  );
}
