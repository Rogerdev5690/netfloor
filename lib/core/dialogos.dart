// ============================================================================
// ETAPA 5 — Diálogos prontos e nome de arquivo seguro
// ============================================================================
// O QUE É:       BusyDialog ("Gerando laudo…"), confirmDialog (Cancelar/Confirmar) e
//                safeFileName (tira acentos e símbolos de nomes de arquivo).
// COMO FUNCIONA: Pequenos blocos reutilizáveis para não repetir código de interface.
// USADO POR:     tela_simulador, tela_laudo, tela_diagnostico, arquivos.
// ONDE MEXER:    Textos padrão dos diálogos; regra de limpeza dos nomes de arquivo.
// ============================================================================
part of '../main.dart';

// ---------------------------------------------------------------------------
// Diálogos utilitários
// ---------------------------------------------------------------------------

class BusyDialog extends StatelessWidget {
  final String message;
  const BusyDialog(this.message, {super.key});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(width: 16),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirmar',
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(confirmLabel)),
      ],
    ),
  );
  return ok ?? false;
}

/// Nome de arquivo seguro (sem acentos, espaços ou símbolos).
String safeFileName(String input) {
  const from = 'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ';
  const to = 'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN';
  final sb = StringBuffer();
  for (final ch in input.trim().split('')) {
    final i = from.indexOf(ch);
    sb.write(i >= 0 ? to[i] : ch);
  }
  final cleaned = sb.toString().replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_').replaceAll(RegExp(r'_+'), '_');
  final trimmed = cleaned.replaceAll(RegExp(r'^_+|_+$'), '');
  return trimmed.isEmpty ? 'netfloor' : trimmed;
}
