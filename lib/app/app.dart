// ============================================================================
// ETAPA 1 — Entrada do app e navegação principal
// ============================================================================
// O QUE É:       WaveLensApp (o MaterialApp) e WaveLensShell (a tela com a barra inferior
//                Simulador / Diagnóstico).
// COMO FUNCIONA: O WaveLensShell é o "dono" do estado compartilhado: cria o NetworkModel
//                (projeto), o DiagnosticsController (Wi-Fi) e o AppStore (armazenamento local).
//                Ao abrir, ele inicia o banco, restaura o tema e o último projeto salvo e só
//                então mostra as telas (IndexedStack preserva o estado de cada aba).
// USADO POR:     main.dart (função main) — é a primeira coisa executada.
// ONDE MEXER:    Nome da aba/ícone da barra inferior, tela inicial, ordem de carregamento (_boot).
// ============================================================================
part of '../main.dart';

class WaveLensApp extends StatelessWidget {
  const WaveLensApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ViewMode>(
      valueListenable: kViewMode,
      builder: (context, mode, _) => MaterialApp(
        title: kAppName,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(mode),
        // Modo Diagnóstico: texto um pouco maior para leitura sob sol forte.
        builder: (context, child) => mode == ViewMode.diagnostic
            ? MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: MediaQuery.textScalerOf(context).clamp(minScaleFactor: 1.08)),
                child: child!,
              )
            : child!,
        home: const WaveLensShell(),
      ),
    );
  }
}

/// Navegação principal: Simulador (mapa de calor) e Diagnóstico (Wi-Fi).
/// Também é dono do estado compartilhado: modelo do projeto, controlador do
/// diagnóstico e armazenamento local (offline-first).
class WaveLensShell extends StatefulWidget {
  const WaveLensShell({super.key});

  @override
  State<WaveLensShell> createState() => _WaveLensShellState();
}

class _WaveLensShellState extends State<WaveLensShell> {
  final DiagnosticsController _diag = DiagnosticsController();
  final NetworkModel _net = NetworkModel();
  final AppStore _store = AppStore();
  int _index = 0;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      await _store.init();
      final mode = await _store.getSetting('viewMode');
      final parsed = ViewMode.values.asNameMap()[mode];
      if (parsed != null) kViewMode.value = parsed;
      await _store.restoreLast(_net);
    } catch (_) {
      // sem armazenamento: segue com o projeto padrão
    }
    _store.attach(_net);
    if (mounted) setState(() => _ready = true);
  }

  @override
  void dispose() {
    _diag.dispose();
    _net.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          TickerMode(enabled: _index == 0, child: SimulatorPage(model: _net, diag: _diag, store: _store)),
          TickerMode(enabled: _index == 1, child: DiagnosticPage(controller: _diag, active: _index == 1, model: _net)),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Simulador'),
          NavigationDestination(
            icon: Icon(Icons.network_check_outlined),
            selectedIcon: Icon(Icons.network_check),
            label: 'Diagnóstico',
          ),
        ],
      ),
    );
  }
}
