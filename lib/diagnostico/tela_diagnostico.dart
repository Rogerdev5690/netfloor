// ============================================================================
// ETAPA 22 — Tela do Diagnóstico (3 abas)
// ============================================================================
// O QUE É:       DiagnosticPage: Espectro, Sinal e Latência, mais o botão "Registrar medição" e os
//                avisos (modo simulação, permissão de localização).
// COMO FUNCIONA: As abas só ficam ativas quando visíveis (economiza bateria). "Registrar medição"
//                liga a medição a um ponto marcado no simulador, para entrar no laudo.
// USADO POR:     app.dart (aba "Diagnóstico").
// ONDE MEXER:    Layout geral da aba e textos dos avisos.
// ============================================================================
part of '../main.dart';

// ---------------------------------------------------------------------------
// Tela do diagnóstico (3 abas)
// ---------------------------------------------------------------------------

class DiagnosticPage extends StatefulWidget {
  final DiagnosticsController controller;
  final bool active;
  final NetworkModel model; // recebe as medições registradas (histórico e pontos do laudo)
  const DiagnosticPage({super.key, required this.controller, required this.active, required this.model});

  @override
  State<DiagnosticPage> createState() => _DiagnosticPageState();
}

class _DiagnosticPageState extends State<DiagnosticPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this)..addListener(_onTabChanged);
    Future.microtask(() => widget.controller.setActive(widget.active));
  }

  void _onTabChanged() {
    if (!_tabs.indexIsChanging) widget.controller.setTab(_tabs.index);
  }

  @override
  void didUpdateWidget(covariant DiagnosticPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      Future.microtask(() => widget.controller.setActive(widget.active));
    }
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  /// Registra uma medição de campo no histórico do projeto, opcionalmente
  /// vinculada a um ponto de medição marcado no simulador.
  Future<void> _recordMeasurement() async {
    final points = widget.model.points;
    MeasurePoint? target;
    if (points.isNotEmpty) {
      final choice = await showModalBottomSheet<Object>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text('Vincular a qual ponto?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              ListTile(
                leading: const Icon(Icons.speed),
                title: const Text('Apenas registrar (sem ponto)'),
                onTap: () => Navigator.pop(ctx, 'none'),
              ),
              for (final p in points)
                ListTile(
                  leading: const Icon(Icons.location_on_outlined),
                  title: Text(p.name),
                  subtitle: Text('${widget.model.floors[p.floor].label}${p.measured == null ? '' : ' · já medido'}'),
                  onTap: () => Navigator.pop(ctx, p),
                ),
            ],
          ),
        ),
      );
      if (choice == null) return;
      if (choice is MeasurePoint) target = choice;
    }
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const BusyDialog('Medindo sinal, ping e perda de pacotes…'),
    );
    String message;
    try {
      final m = await widget.controller.captureSnapshot();
      widget.model.recordMeasurement(m, point: target);
      message = 'Medição registrada${target == null ? '' : ' em ${target.name}'}: ${m.rssi} dBm'
          '${m.native ? '' : ' (dados simulados)'}';
    } catch (e) {
      message = 'Falha na medição: $e';
    }
    if (mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.network_check),
            SizedBox(width: 8),
            Text('$kAppName Diagnostic'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_location_alt_outlined),
            tooltip: 'Registrar medição (RSSI + ping + perda)',
            onPressed: _recordMeasurement,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.graphic_eq), text: 'Espectro'),
            Tab(icon: Icon(Icons.show_chart), text: 'Sinal'),
            Tab(icon: Icon(Icons.speed), text: 'Latência'),
          ],
        ),
      ),
      body: AnimatedBuilder(
        animation: c,
        builder: (context, _) {
          return Column(
            children: [
              _SourceBanner(native: c.isNative),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    SpectrumTab(c: c),
                    SignalTab(c: c),
                    LatencyTab(c: c),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SourceBanner extends StatelessWidget {
  final bool native;
  const _SourceBanner({required this.native});

  @override
  Widget build(BuildContext context) {
    final color = native ? Colors.green.shade50 : Colors.amber.shade100;
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(native ? Icons.verified_outlined : Icons.science_outlined, size: 18, color: Colors.black87),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              native
                  ? 'Dados reais do aparelho Android.'
                  : 'Modo simulação: dados fictícios. Abra o WaveLens no app Android (WaveLens Shell 3.0+) para a varredura real.',
              style: const TextStyle(fontSize: 12, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  final DiagnosticsController c;
  const _PermissionCard({required this.c});

  @override
  Widget build(BuildContext context) {
    final p = c.permissions;
    if (!c.isNative || p == null) return const SizedBox.shrink();
    if (p.granted && p.locationServicesEnabled) return const SizedBox.shrink();
    final message = !p.granted
        ? 'O Android exige a permissão de Localização para varrer redes Wi-Fi e ler o sinal.'
        : 'Ative a Localização (GPS) do aparelho: sem ela o Android não retorna as redes Wi-Fi.';
    return Card(
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.location_off_outlined, color: Colors.deepOrange),
            const SizedBox(width: 12),
            Expanded(child: Text(message, style: const TextStyle(fontSize: 13, color: Colors.black87))),
            const SizedBox(width: 8),
            FilledButton(onPressed: c.requestPermissions, child: const Text('Conceder')),
          ],
        ),
      ),
    );
  }
}
