/* Keep the full source URL while presenting the filename used by Learn. */
(function () {
  var languageNames = {
    bash: 'Bash',
    c: 'C',
    cpp: 'C++',
    cs: 'C#',
    csharp: 'C#',
    css: 'CSS',
    fsharp: 'F#',
    html: 'HTML',
    javascript: 'JavaScript',
    json: 'JSON',
    powershell: 'PowerShell',
    ps1: 'PowerShell',
    shell: 'Shell',
    text: 'Text',
    typescript: 'TypeScript',
    vb: 'Visual Basic',
    visualbasic: 'Visual Basic',
    xml: 'XML',
    yaml: 'YAML'
  };

  function shortenSourceLabels() {
    document.querySelectorAll('.facts a[href]').forEach(function (link) {
      var label = link.textContent.trim();
      var separator = Math.max(label.lastIndexOf('/'), label.lastIndexOf('\\'));
      if (separator >= 0 && separator < label.length - 1) {
        link.textContent = label.substring(separator + 1);
      }
    });
  }

  function labelCodeLanguages() {
    document.querySelectorAll('.codewrapper').forEach(function (wrapper) {
      var code = wrapper.querySelector('pre code');
      var className = code ? code.className : '';
      var match = className.match(/(?:^|\s)(?:lang|language)-([^\s]+)/i);
      var language = match ? match[1].toLowerCase() : 'code';
      var label = languageNames[language] || language.charAt(0).toUpperCase() + language.slice(1);

      wrapper.setAttribute('data-code-language', label);
    });
  }

  function initialize() {
    shortenSourceLabels();
    labelCodeLanguages();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initialize);
  } else {
    initialize();
  }
})();
