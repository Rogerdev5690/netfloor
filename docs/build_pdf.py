#!/usr/bin/env python3
"""Gera docs/Documentacao_Tecnica_App.pdf a partir de docs/DOCUMENTACAO.md.

Pipeline: Markdown -> HTML (fórmulas LaTeX viram MathML) -> PDF (Chrome headless)
-> 2ª passada para preencher os números de página do sumário -> rodapé com
numeração e marcadores (bookmarks) via pypdf/reportlab.

Dependências: pip install markdown latex2mathml pygments pypdf reportlab
Requer o Google Chrome (ou Edge) instalado.
"""
import html
import io
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import latex2mathml.converter as l2m
import markdown
from pygments.formatters import HtmlFormatter
from pypdf import PdfReader, PdfWriter
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.pdfgen import canvas

DOCS = Path(__file__).resolve().parent
SRC = DOCS / "DOCUMENTACAO.md"
OUT = DOCS / "Documentacao_Tecnica_App.pdf"
BUILD = DOCS / "_build"

CHROME_CANDIDATES = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
]


def find_chrome() -> str:
    for c in CHROME_CANDIDATES:
        if Path(c).exists():
            return c
    for name in ("chrome", "google-chrome", "chromium", "msedge"):
        p = shutil.which(name)
        if p:
            return p
    sys.exit("Chrome/Edge não encontrado: instale o Google Chrome para gerar o PDF.")


# --------------------------------------------------------------------------
# Markdown -> HTML
# --------------------------------------------------------------------------

def read_meta(text: str):
    def get(key, default):
        m = re.search(rf"<!--\s*{key}:\s*(.+?)\s*-->", text)
        return m.group(1) if m else default

    meta = {
        "version": get("doc-version", "?"),
        "revision": get("doc-revision", ""),
        "date": get("doc-date", ""),
    }
    text = re.sub(r"<!--\s*doc-[a-z]+:.*?-->\s*", "", text)
    return meta, text


def convert_markdown(text: str):
    """Converte o Markdown em HTML e devolve (html, toc_tokens)."""
    keep = []

    def stash(m):
        keep.append(m.group(0))
        return f"@@KEEP{len(keep) - 1}@@"

    text = re.sub(r"```.*?```", stash, text, flags=re.S)
    text = re.sub(r"`[^`\n]+`", stash, text)

    maths = []

    def block(m):
        maths.append(("block", m.group(1).strip()))
        return f"\n\n@@MATH{len(maths) - 1}@@\n\n"

    def inline(m):
        maths.append(("inline", m.group(1).strip()))
        return f"@@MATH{len(maths) - 1}@@"

    text = re.sub(r"\$\$(.+?)\$\$", block, text, flags=re.S)
    text = re.sub(r"(?<!\\)\$([^$\n]+?)\$", inline, text)

    for i, s in enumerate(keep):
        text = text.replace(f"@@KEEP{i}@@", s)

    md = markdown.Markdown(
        extensions=["tables", "fenced_code", "codehilite", "toc", "sane_lists", "attr_list"],
        extension_configs={
            "codehilite": {"guess_lang": False, "css_class": "codehilite"},
            "toc": {"toc_depth": "2-3"},
        },
    )
    body = md.convert(text)

    for i, (kind, latex) in enumerate(maths):
        try:
            ml = l2m.convert(latex, display="block" if kind == "block" else "inline")
        except Exception as e:  # fórmula inválida: mostra o LaTeX cru
            ml = f"<code>{html.escape(latex)}</code>"
            print(f"[aviso] fórmula não convertida ({e}): {latex[:60]}")
        if kind == "block":
            body = body.replace(f"<p>@@MATH{i}@@</p>", f'<div class="math-block">{ml}</div>')
        body = body.replace(f"@@MATH{i}@@", f'<span class="math-inline">{ml}</span>')

    # imagens viram figuras com legenda
    body = re.sub(
        r'<p><img alt="([^"]*)" src="([^"]*)"\s*/?></p>',
        r'<figure><img alt="\1" src="\2"><figcaption>\1</figcaption></figure>',
        body,
    )
    return body, md.toc_tokens


def flatten_headings(tokens):
    out = []
    for t in tokens:
        out.append((t["id"], t["name"], t["level"]))
        for c in t.get("children", []):
            out.append((c["id"], c["name"], c["level"]))
    return out


CSS = """
@page { size: A4; margin: 20mm 17mm 24mm 17mm; }
* { box-sizing: border-box; }
html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body { font-family: 'Segoe UI', Calibri, Arial, sans-serif; font-size: 10pt; line-height: 1.5; color: #1e293b; margin: 0; }
h1, h2, h3, h4 { font-family: 'Segoe UI Semibold', 'Segoe UI', Arial, sans-serif; color: #312e81; line-height: 1.25; }
h2 { font-size: 19pt; border-bottom: 3px solid #6366f1; padding-bottom: 5pt; margin: 0 0 12pt; break-before: page; }
h2:first-of-type { break-before: auto; }
h3 { font-size: 13pt; margin: 18pt 0 6pt; color: #3730a3; break-after: avoid; }
p { margin: 0 0 7pt; text-align: justify; }
a { color: #4338ca; text-decoration: none; }
ul, ol { margin: 0 0 8pt; padding-left: 18pt; }
li { margin-bottom: 2pt; }
table { border-collapse: collapse; width: 100%; font-size: 9pt; margin: 8pt 0 12pt; }
thead { display: table-header-group; }
th { background: #312e81; color: #fff; text-align: left; padding: 5px 7px; border: 1px solid #312e81; }
td { border: 1px solid #cbd5e1; padding: 4px 7px; vertical-align: top; }
tr { break-inside: avoid; }
tbody tr:nth-child(even) td { background: #f5f7ff; }
code { font-family: Consolas, 'Cascadia Mono', monospace; font-size: 8.8pt; background: #eef2ff; color: #3730a3; padding: 0 3px; border-radius: 3px; }
.codehilite { background: #f8fafc; border: 1px solid #e2e8f0; border-left: 4px solid #6366f1; border-radius: 4px; margin: 8pt 0 12pt; padding: 8px 10px; break-inside: avoid; }
.codehilite pre { margin: 0; white-space: pre-wrap; word-break: break-word; font-family: Consolas, 'Cascadia Mono', monospace; font-size: 8.3pt; line-height: 1.4; }
.codehilite code { background: none; color: inherit; padding: 0; font-size: inherit; }
blockquote { border-left: 4px solid #f59e0b; background: #fffbeb; margin: 10pt 0; padding: 6pt 12pt; }
blockquote p { margin: 0; }
figure { margin: 10pt 0 14pt; text-align: center; break-inside: avoid; }
figure img { max-width: 100%; border: 1px solid #e2e8f0; border-radius: 6px; }
figcaption { font-size: 8.5pt; color: #64748b; margin-top: 3pt; font-style: italic; }
.math-block { text-align: center; margin: 10pt 0; font-size: 12.5pt; break-inside: avoid; }
math { font-family: 'Cambria Math', 'STIX Two Math', 'Times New Roman', serif; }
.marker { position: absolute; font-size: 1px; color: #fff; }
input[type=checkbox] { margin-right: 4px; }

/* capa */
.cover { width: 210mm; height: 297mm; padding: 26mm 22mm; color: #fff; break-after: page;
  background: linear-gradient(155deg, #1e1b4b 0%, #312e81 45%, #4f46e5 100%); position: relative; }
.cover .tag { letter-spacing: 4px; font-size: 10.5pt; color: #c7d2fe; margin-bottom: 70mm; }
.cover .logo { width: 34mm; height: 34mm; margin-bottom: 8mm; }
.cover h1 { color: #fff; font-size: 54pt; margin: 0 0 4mm; letter-spacing: -1px; }
.cover .sub { font-size: 16pt; color: #e0e7ff; line-height: 1.35; max-width: 150mm; text-align: left; }
.cover .ver { margin-top: 16mm; display: inline-block; background: #fff; color: #312e81; font-weight: 700;
  font-size: 15pt; padding: 6px 16px; border-radius: 30px; }
.cover .ver span { font-weight: 400; font-size: 11pt; color: #6366f1; margin-left: 8px; }
.cover .date { margin-top: 6mm; color: #c7d2fe; font-size: 11pt; }
.cover .foot { position: absolute; left: 22mm; right: 22mm; bottom: 22mm; font-size: 9.5pt; color: #c7d2fe;
  border-top: 1px solid rgba(255,255,255,.35); padding-top: 6mm; line-height: 1.7; }
.cover .foot b { color: #fff; }

/* sumário */
.toc { break-after: page; padding: 0; }
.toc h1 { font-size: 24pt; color: #312e81; border-bottom: 3px solid #6366f1; padding-bottom: 6pt; margin: 0 0 14pt; }
.toc ul { list-style: none; padding: 0; margin: 0; }
.toc li { margin: 0; }
.toc a { display: flex; align-items: baseline; color: #1e293b; }
.toc li.l2 { margin-top: 7pt; font-weight: 700; font-size: 10.5pt; }
.toc li.l2 a { color: #312e81; }
.toc li.l3 { font-size: 9.5pt; padding-left: 16pt; }
.toc .t { white-space: nowrap; }
.toc .dots { flex: 1; border-bottom: 1px dotted #94a3b8; margin: 0 5px; transform: translateY(-3px); }
.toc .pg { min-width: 20px; text-align: right; }
.body { padding: 0; }
"""


def logo_svg() -> str:
    return (
        '<svg class="logo" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg" fill="none" '
        'stroke="#fff" stroke-width="7" stroke-linecap="round">'
        '<path d="M18 40 A45 45 0 0 1 82 40"/><path d="M28 52 A30 30 0 0 1 72 52"/>'
        '<path d="M38 64 A16 16 0 0 1 62 64"/><circle cx="50" cy="78" r="4" fill="#fff"/></svg>'
    )


def build_cover_html(meta) -> str:
    rev = f"<span>revisão {html.escape(meta['revision'])}</span>" if meta["revision"] else ""
    return f"""<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8"><title>NetFloor — Capa</title>
<style>@page {{ size: A4; margin: 0; }}
{CSS.replace("@page { size: A4; margin: 20mm 17mm 24mm 17mm; }", "")}</style></head><body>
<section class="cover">
  <div class="tag">DOCUMENTAÇÃO TÉCNICA</div>
  {logo_svg()}
  <h1>NetFloor</h1>
  <div class="sub">Simulador de Cobertura Wi-Fi 2.5D e Diagnóstico de Campo Nativo</div>
  <div class="ver">Versão {html.escape(meta['version'])} {rev}</div>
  <div class="date">Atualizada em {html.escape(meta['date'])}</div>
  <div class="foot">
    <b>Stack:</b> Flutter / Dart · Kotlin (Android) · GitHub Pages (PWA) · JS Bridge<br>
    <b>Aplicativo:</b> rogerdev5690.github.io/netfloor<br>
    <b>Código:</b> github.com/Rogerdev5690/netfloor · github.com/Rogerdev5690/netfloor-shell
  </div>
</section></body></html>"""


def build_body_html(body: str, headings, pages) -> str:
    toc_items = []
    for hid, title, level in headings:
        pg = pages.get(hid, "")
        cls = "l2" if level == 2 else "l3"
        toc_items.append(
            f'<li class="{cls}"><a href="#{hid}"><span class="t">{html.escape(title)}</span>'
            f'<span class="dots"></span><span class="pg">{pg}</span></a></li>'
        )
    pygments_css = HtmlFormatter(style="default").get_style_defs(".codehilite")
    return f"""<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8">
<title>NetFloor — Documentação Técnica</title>
<base href="{DOCS.as_uri()}/">
<style>{CSS}
{pygments_css}</style></head><body>
<section class="toc"><h1>Sumário</h1><ul>{''.join(toc_items)}</ul></section>
<div class="body"><span class="marker">NFCORPOINICIO</span>
{body}
</div>
</body></html>"""


# --------------------------------------------------------------------------
# PDF
# --------------------------------------------------------------------------

def print_pdf(html_path: Path, pdf_path: Path):
    profile = tempfile.mkdtemp(prefix="nf_chrome_")
    cmd = [
        find_chrome(), "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
        "--allow-file-access-from-files", "--virtual-time-budget=20000",
        f"--user-data-dir={profile}", f"--print-to-pdf={pdf_path}", html_path.as_uri(),
    ]
    subprocess.run(cmd, check=True, timeout=240, capture_output=True)
    shutil.rmtree(profile, ignore_errors=True)
    if not pdf_path.exists() or pdf_path.stat().st_size < 10_000:
        sys.exit("Falha ao gerar o PDF pelo Chrome.")


def norm(s: str) -> str:
    return re.sub(r"\s+", "", s).lower()


def find_pages(pdf_path: Path, headings):
    reader = PdfReader(str(pdf_path))
    texts = [norm(p.extract_text() or "") for p in reader.pages]
    start = next((i for i, t in enumerate(texts) if "nfcorpoinicio" in t), 2)
    pages, cur = {}, start
    for hid, title, _ in headings:
        key = norm(title)
        found = next((i for i in range(cur, len(texts)) if key in texts[i]), None)
        if found is None:
            found = next((i for i in range(cur, len(texts)) if key[:24] in texts[i]), cur)
        pages[hid] = found
        cur = found
    return pages, start, len(texts)


def finalize(cover_pdf: Path, body_pdf: Path, out_pdf: Path, headings, pages, meta):
    writer = PdfWriter(clone_from=PdfReader(str(body_pdf)))
    writer.insert_page(PdfReader(str(cover_pdf)).pages[0], 0)
    total = len(writer.pages)
    label = f"NetFloor — Documentação Técnica · v{meta['version']}"
    if meta["revision"]:
        label += f" (rev. {meta['revision']})"
    label += f" · {meta['date']}"

    for i in range(1, total):
        packet = io.BytesIO()
        c = canvas.Canvas(packet, pagesize=A4)
        c.setStrokeColorRGB(0.8, 0.83, 0.9)
        c.line(17 * mm, 15 * mm, A4[0] - 17 * mm, 15 * mm)
        c.setFillColorRGB(0.39, 0.45, 0.55)
        c.setFont("Helvetica", 8)
        c.drawString(17 * mm, 10.5 * mm, label)
        c.drawRightString(A4[0] - 17 * mm, 10.5 * mm, f"Página {i + 1} de {total}")
        c.save()
        packet.seek(0)
        writer.pages[i].merge_page(PdfReader(packet).pages[0])

    if "/Outlines" in writer._root_object:
        del writer._root_object["/Outlines"]
    writer.add_outline_item("Capa", 0)
    writer.add_outline_item("Sumário", 1)
    parent = None
    for hid, title, level in headings:
        if level == 2:
            parent = writer.add_outline_item(title, pages[hid] + 1)
        else:
            writer.add_outline_item(title, pages[hid] + 1, parent=parent)
    for page in writer.pages:
        page.compress_content_streams()
    writer.compress_identical_objects(remove_identicals=True, remove_orphans=True)
    writer.page_mode = "/UseOutlines"
    writer.add_metadata({
        "/Title": f"NetFloor — Documentação Técnica v{meta['version']}",
        "/Author": "NetFloor",
        "/Subject": "Documentação técnica completa do aplicativo NetFloor",
    })
    with open(out_pdf, "wb") as f:
        writer.write(f)


def main():
    meta, text = read_meta(SRC.read_text(encoding="utf-8"))
    body, tokens = convert_markdown(text)
    headings = flatten_headings(tokens)
    BUILD.mkdir(exist_ok=True)
    body_html, body_pdf = BUILD / "corpo.html", BUILD / "corpo.pdf"
    cover_html, cover_pdf = BUILD / "capa.html", BUILD / "capa.pdf"

    cover_html.write_text(build_cover_html(meta), encoding="utf-8")
    print_pdf(cover_html, cover_pdf)

    pages = {}
    for _ in range(3):  # 1ª passada mede as páginas; as seguintes confirmam
        shown = {k: v + 2 for k, v in pages.items()}  # +1 da capa, +1 para contar de 1
        body_html.write_text(build_body_html(body, headings, shown), encoding="utf-8")
        print_pdf(body_html, body_pdf)
        new_pages, _, total = find_pages(body_pdf, headings)
        if new_pages == pages:
            break
        pages = new_pages

    finalize(cover_pdf, body_pdf, OUT, headings, pages, meta)
    shutil.rmtree(BUILD, ignore_errors=True)
    print(f"OK: {OUT} ({total + 1} paginas, {OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
