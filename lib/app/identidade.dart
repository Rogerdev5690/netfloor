// ============================================================================
// ETAPA 2 — Nome e versão do produto
// ============================================================================
// O QUE É:       As constantes kAppVersion e kAppName.
// COMO FUNCIONA: São usadas no título do app, no cabeçalho das telas e no rodapé/metadados do PDF.
// USADO POR:     tela_simulador, tela_diagnostico, gerador_pdf, network_model (exportação .json).
// ONDE MEXER:    Troque aqui o nome ou a versão exibidos — um lugar só.
// ============================================================================
part of '../main.dart';

const String kAppVersion = '8.2';

/// Nome do produto exibido ao usuário (título, cabeçalhos, laudo em PDF).
/// Identificadores técnicos internos (bridge `NetFloorNative`, formato de
/// arquivo `netfloor-project`, repositórios/URL) não mudam com o rebranding.
const String kAppName = 'WaveLens';
