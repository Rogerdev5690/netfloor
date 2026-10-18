// ============================================================================
// ETAPA 4 — Funções pequenas compartilhadas
// ============================================================================
// O QUE É:       Formatação de data/hora (_fmtDate, _fmtDateTime, _two, _clock), cor de texto
//                secundário que funciona nos dois temas (_muted) e cor da classe de sinal
//                (_signalClassColor: verde/âmbar/vermelho).
// COMO FUNCIONA: São funções puras e curtas, usadas por várias telas.
// USADO POR:     simulador, diagnóstico e laudo.
// ONDE MEXER:    Formato das datas (dd/mm/aaaa) e as cores de Forte / Intermediário / Ruim.
// ============================================================================
part of '../main.dart';

Color _signalClassColor(double dbm) {
  if (dbm >= kStrongDbm) return const Color(0xFF16A34A);
  if (dbm >= kWeakDbm) return const Color(0xFFD97706);
  return const Color(0xFFDC2626);
}

/// Cor de texto secundário que funciona nos dois temas.
Color _muted(BuildContext context) => Theme.of(context).colorScheme.onSurfaceVariant;

String _fmtDate(DateTime t) => '${_two(t.day)}/${_two(t.month)}/${t.year}';
String _fmtDateTime(DateTime t) => '${_fmtDate(t)} ${_two(t.hour)}:${_two(t.minute)}';


String _two(int v) => v.toString().padLeft(2, '0');
String _clock(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
