// ============================================================================
// ETAPA 3 — Temas: Modo Apresentação e Modo Diagnóstico
// ============================================================================
// O QUE É:       Dois visuais do app: Apresentação (escuro, para mostrar ao cliente) e
//                Diagnóstico (alto contraste, legível sob sol forte).
// COMO FUNCIONA: kViewMode guarda o modo atual (ValueNotifier); buildTheme(modo) monta o ThemeData
//                Material 3 de cada um; setViewMode salva a escolha no armazenamento local.
// USADO POR:     app.dart (MaterialApp) e tela_simulador (botão de contraste).
// ONDE MEXER:    Cores e estilos de botões, chips, barras e cartões de cada modo (buildTheme).
// ============================================================================
part of '../main.dart';

// ---------------------------------------------------------------------------
// Modos de visualização
//   - Apresentação: escuro/moderno, para mostrar ao cliente.
//   - Diagnóstico: alto contraste (preto/branco/amarelo), legível sob sol forte.
// ---------------------------------------------------------------------------

enum ViewMode { presentation, diagnostic }

final ValueNotifier<ViewMode> kViewMode = ValueNotifier<ViewMode>(ViewMode.presentation);

void setViewMode(ViewMode mode, AppStore store) {
  kViewMode.value = mode;
  unawaited(store.setSetting('viewMode', mode.name));
}

ThemeData buildTheme(ViewMode mode) {
  if (mode == ViewMode.diagnostic) {
    const yellow = Color(0xFFFFD400);
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0033A0)).copyWith(
      primary: const Color(0xFF0033A0),
      onPrimary: Colors.white,
      surface: Colors.white,
      onSurface: Colors.black,
      onSurfaceVariant: const Color(0xFF1F1F1F),
      outline: Colors.black,
      outlineVariant: const Color(0xFF444444),
      surfaceContainerHighest: const Color(0xFFE9E9E9),
      primaryContainer: yellow,
      onPrimaryContainer: Colors.black,
    );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    return base.copyWith(
      scaffoldBackgroundColor: Colors.white,
      textTheme: base.textTheme.apply(bodyColor: Colors.black, displayColor: Colors.black),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        titleTextStyle: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Colors.black, width: 1.4)),
      ),
      chipTheme: ChipThemeData(
        side: const BorderSide(color: Colors.black, width: 1.3),
        selectedColor: yellow,
        backgroundColor: Colors.white,
        labelStyle: const TextStyle(color: Colors.black, fontWeight: FontWeight.w700),
        checkmarkColor: Colors.black,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.white,
        indicatorColor: yellow,
        labelTextStyle: WidgetStateProperty.all(const TextStyle(fontWeight: FontWeight.w700, color: Colors.black, fontSize: 12)),
        iconTheme: WidgetStateProperty.all(const IconThemeData(color: Colors.black)),
      ),
      dividerTheme: const DividerThemeData(color: Colors.black, thickness: 1),
      tabBarTheme: const TabBarThemeData(
        labelColor: Colors.white,
        unselectedLabelColor: Color(0xFFCCCCCC),
        indicatorColor: yellow,
        labelStyle: TextStyle(fontWeight: FontWeight.w700),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(backgroundColor: Colors.black, foregroundColor: Colors.white),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(foregroundColor: Colors.black, side: const BorderSide(color: Colors.black, width: 1.5)),
      ),
    );
  }

  const bg = Color(0xFF0B1020);
  const card = Color(0xFF141B31);
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF6366F1), brightness: Brightness.dark).copyWith(
    surface: bg,
    surfaceContainerHighest: const Color(0xFF1B2440),
    primary: const Color(0xFF8B93FF),
    onPrimary: const Color(0xFF0B1020),
    primaryContainer: const Color(0xFF2A3266),
    onPrimaryContainer: Colors.white,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: Brightness.dark);
  return base.copyWith(
    scaffoldBackgroundColor: bg,
    appBarTheme: const AppBarTheme(backgroundColor: bg, foregroundColor: Colors.white, elevation: 0, scrolledUnderElevation: 0),
    cardTheme: CardThemeData(
      color: card,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xFF0F1526),
      indicatorColor: const Color(0xFF2A3266),
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: Color(0xFF10172B)),
    dialogTheme: DialogThemeData(backgroundColor: const Color(0xFF10172B), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
  );
}
