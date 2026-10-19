window.renderDocumentContent = async ({kind, source, width, fontSize, dark}) => {
  const output = document.getElementById('output');
  output.replaceChildren();
  output.style.color = dark ? '#eeeeee' : '#222222';
  output.style.fontSize = `${fontSize}px`;
  output.style.width = kind === 'inlineMath' ? 'max-content' : `${width}px`;
  if (source.length > 50000) throw new Error('Source exceeds 50,000 characters');
  if (kind === 'mermaid') {
    documentMermaid.initialize({startOnLoad:false, securityLevel:'strict', theme:dark?'dark':'default',
      maxTextSize:50000, maxEdges:500, suppressErrorRendering:true,
      fontFamily:'-apple-system, sans-serif'});
    const {svg} = await documentMermaid.render('diagram', source);
    output.innerHTML = svg;
  } else {
    const formula = document.createElement('span');
    output.appendChild(formula);
    katex.render(source, formula, {displayMode:kind==='displayMath', throwOnError:true,
      trust:false, maxExpand:1000, maxSize:20, output:'htmlAndMathml'});
    if (kind === 'inlineMath') {
      const marker = document.createElement('span'); marker.id='baseline'; output.appendChild(marker);
    }
  }
  // Trigger font discovery before waiting; otherwise a snapshot can omit math italic
  // and size-extension glyphs while already-loaded digits remain visible.
  output.getBoundingClientRect();
  await document.fonts.ready;

  const box = output.getBoundingClientRect();
  const marker = document.getElementById('baseline');
  const parts = [...output.querySelectorAll('.katex-html > .katex-base, .katex-html > .base, .katex-html > .tag')]
    .map(node => node.getBoundingClientRect());
  const contentLeft = parts.length ? Math.min(...parts.map(rect => rect.left)) : box.left;
  const contentRight = parts.length ? Math.max(...parts.map(rect => rect.right)) : box.right;
  return {width:Math.ceil(box.width), height:Math.ceil(box.height),
    contentX:Math.max(0,contentLeft-box.left), contentWidth:Math.min(box.width,contentRight-contentLeft),
    baseline:marker ? marker.getBoundingClientRect().top-box.top : box.height};
};
