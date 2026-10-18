// ============================================================================
// ETAPA 29 — Tela do Laudo de vistoria
// ============================================================================
// O QUE É:       ReportPage: formulário (técnico, empresa, logo, cliente, endereço, data), escolha
//                das bandas, observações, assinatura e os botões "Gerar" / "Gerar e compartilhar".
// COMO FUNCIONA: Cada campo grava direto no ReportInfo do projeto (e salva sozinho). O botão chama
//                LaudoPdf.build e entrega o arquivo com FileIO.deliver.
// USADO POR:     tela_simulador (ícone de documento).
// ONDE MEXER:    Campos do formulário e textos da tela.
// ============================================================================
part of '../main.dart';

// ---------------------------------------------------------------------------
// Tela do laudo de vistoria
// ---------------------------------------------------------------------------

class ReportPage extends StatefulWidget {
  final NetworkModel model;
  final DiagnosticsController diag;
  final AppStore store;
  const ReportPage({super.key, required this.model, required this.diag, required this.store});

  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  NetworkModel get _m => widget.model;
  ReportInfo get _r => _m.report;

  late final TextEditingController _technician = TextEditingController(text: _r.technician);
  late final TextEditingController _company = TextEditingController(text: _r.company);
  late final TextEditingController _client = TextEditingController(text: _r.client);
  late final TextEditingController _address = TextEditingController(text: _r.address);
  late final TextEditingController _notes = TextEditingController(text: _r.notes);
  late final TextEditingController _signer = TextEditingController(text: _r.signerName);
  late final Set<RfBand> _bands = {_m.band};

  @override
  void dispose() {
    for (final c in [_technician, _company, _client, _address, _notes, _signer]) {
      c.dispose();
    }
    super.dispose();
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _pickLogo() async {
    try {
      final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp']);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      // valida que a imagem decodifica
      final codec = await ui.instantiateImageCodec(bytes);
      codec.dispose();
      setState(() => _r.logo = bytes);
      _m.touch();
    } catch (e) {
      if (mounted) _snack('Não foi possível carregar o logo: $e');
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _r.date ?? now,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() => _r.date = d);
      _m.touch();
    }
  }

  Future<void> _collectSignature() async {
    final png = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => SignaturePadPage(signerName: _signer.text.trim().isEmpty ? _client.text.trim() : _signer.text.trim())),
    );
    if (png == null) return;
    setState(() {
      _r.signature = png;
      _r.signedAt = DateTime.now();
      if (_r.signerName.isEmpty && _client.text.trim().isNotEmpty) {
        _r.signerName = _client.text.trim();
        _signer.text = _r.signerName;
      }
    });
    _m.touch();
  }

  Future<void> _generate({required bool share}) async {
    if (_m.routers.isEmpty) {
      _snack('Adicione ao menos um roteador no simulador para gerar o mapa de calor do laudo.');
      return;
    }
    if (_bands.isEmpty) {
      _snack('Selecione ao menos uma banda para o laudo.');
      return;
    }
    showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const BusyDialog('Gerando o laudo em PDF…'));
    String message;
    try {
      final bytes = await LaudoPdf.build(_m, bands: RfBand.values.where(_bands.contains).toList());
      final date = _r.date ?? DateTime.now();
      final who = _r.client.trim().isEmpty ? _m.workspaceName : _r.client;
      final name = 'Laudo_${safeFileName(who)}_${date.year}${_two(date.month)}${_two(date.day)}.pdf';
      message = await FileIO.deliver(name, 'application/pdf', bytes, share: share);
    } catch (e) {
      message = 'Não foi possível gerar/salvar o laudo: $e';
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (mounted) _snack(message);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Laudo de vistoria')),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: _m,
          builder: (context, _) {
            final measured = _m.logs.length;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _section('Dados do laudo'),
                TextField(
                  controller: _technician,
                  decoration: const InputDecoration(labelText: 'Técnico responsável', border: OutlineInputBorder()),
                  onChanged: (v) {
                    _r.technician = v;
                    _m.touch();
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _company,
                  decoration: const InputDecoration(labelText: 'Empresa / Provedor (ISP)', border: OutlineInputBorder()),
                  onChanged: (v) {
                    _r.company = v;
                    _m.touch();
                  },
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                        borderRadius: BorderRadius.circular(10),
                        color: Colors.white,
                      ),
                      alignment: Alignment.center,
                      child: _r.logo == null
                          ? const Icon(Icons.image_outlined, color: Colors.black38)
                          : Padding(padding: const EdgeInsets.all(4), child: Image.memory(_r.logo!, fit: BoxFit.contain)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _pickLogo,
                            icon: const Icon(Icons.upload_file),
                            label: Text(_r.logo == null ? 'Enviar logo da empresa' : 'Trocar logo'),
                          ),
                          if (_r.logo != null)
                            TextButton(
                              onPressed: () {
                                setState(() => _r.logo = null);
                                _m.touch();
                              },
                              child: const Text('Remover'),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _client,
                  decoration: const InputDecoration(labelText: 'Cliente', border: OutlineInputBorder()),
                  onChanged: (v) {
                    _r.client = v;
                    _m.touch();
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _address,
                  decoration: const InputDecoration(labelText: 'Endereço da vistoria', border: OutlineInputBorder()),
                  onChanged: (v) {
                    _r.address = v;
                    _m.touch();
                  },
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.event),
                  label: Text('Data da vistoria: ${_fmtDate(_r.date ?? DateTime.now())}${_r.date == null ? ' (hoje)' : ''}'),
                ),
                _section('Conteúdo do laudo'),
                Text(
                  'Projeto "${_m.workspaceName}": ${_m.floors.length} pavimento(s), ${_m.routers.length} roteador(es), '
                  '${_m.points.length} ponto(s) de medição, $measured medição(ões) de campo.',
                ),
                const SizedBox(height: 8),
                const Text('Bandas com mapa de calor no laudo:', style: TextStyle(fontWeight: FontWeight.w600)),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final b in kRfBands)
                      FilterChip(
                        label: Text(b.label),
                        selected: _bands.contains(b.band),
                        onSelected: (v) => setState(() => v ? _bands.add(b.band) : _bands.remove(b.band)),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                if (!_m.floors.every((f) => f.calibrated))
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.straighten, size: 18, color: Colors.amber),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Há pavimento(s) com escala estimada. Use a Régua no simulador para calibrar as distâncias reais.',
                          style: TextStyle(fontSize: 12, color: _muted(context)),
                        ),
                      ),
                    ],
                  ),
                _section('Observações do técnico'),
                TextField(
                  controller: _notes,
                  minLines: 4,
                  maxLines: 10,
                  decoration: const InputDecoration(
                    hintText: 'Recomendações, pontos de atenção, equipamentos sugeridos…',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    _r.notes = v;
                    _m.touch();
                  },
                ),
                _section('Assinatura do cliente'),
                TextField(
                  controller: _signer,
                  decoration: const InputDecoration(labelText: 'Nome de quem assina', border: OutlineInputBorder()),
                  onChanged: (v) {
                    _r.signerName = v;
                    _m.touch();
                  },
                ),
                const SizedBox(height: 10),
                if (_r.signature != null)
                  Container(
                    height: 110,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                    ),
                    child: Image.memory(_r.signature!, fit: BoxFit.contain),
                  ),
                if (_r.signedAt != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('Assinado em ${_fmtDateTime(_r.signedAt!)}', style: TextStyle(fontSize: 12, color: _muted(context))),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: _collectSignature,
                      icon: const Icon(Icons.draw_outlined),
                      label: Text(_r.signature == null ? 'Coletar assinatura' : 'Refazer assinatura'),
                    ),
                    if (_r.signature != null)
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _r.signature = null;
                            _r.signedAt = null;
                          });
                          _m.touch();
                        },
                        child: const Text('Remover'),
                      ),
                  ],
                ),
                _section('Registro de diagnósticos ($measured)'),
                if (measured == 0)
                  Text(
                    'Nenhuma medição de campo registrada. Marque pontos no simulador (ferramenta Ponto → Medir agora) '
                    'ou use "Registrar medição" na aba Diagnóstico.',
                    style: TextStyle(fontSize: 13, color: _muted(context)),
                  )
                else ...[
                  for (final l in _m.logs.reversed.take(8))
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(l.native ? Icons.verified_outlined : Icons.science_outlined, size: 20),
                      title: Text('${l.pointName ?? 'Sem ponto'} · ${l.rssi} dBm · PHY ${l.linkMbps} Mbps'),
                      subtitle: Text(
                        '${_fmtDateTime(l.time)} · ${l.native ? 'real' : 'simulado'} · '
                        'GW ${l.gwAvgMs?.toStringAsFixed(1) ?? '—'} ms · Internet ${l.netAvgMs?.toStringAsFixed(0) ?? '—'} ms · '
                        'perda ${l.netLossPct.toStringAsFixed(0)}%',
                      ),
                    ),
                  if (measured > 8) Text('… e mais ${measured - 8} registro(s) (todos entram no PDF).', style: const TextStyle(fontSize: 12)),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        final ok = await confirmDialog(
                          context,
                          title: 'Apagar registros?',
                          message: 'Todas as medições de campo deste projeto serão removidas.',
                          confirmLabel: 'Apagar',
                        );
                        if (ok) _m.clearLogs();
                      },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Apagar registros'),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => _generate(share: false),
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('Gerar laudo em PDF')),
                ),
                if (NativeBridge.available) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => _generate(share: true),
                    icon: const Icon(Icons.share_outlined),
                    label: const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Gerar e compartilhar')),
                  ),
                ],
                const SizedBox(height: 24),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 10),
        child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      );
}
